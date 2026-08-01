defmodule TimelessCanvas.Web.CanvasLiveTest do
  # async: false — shares FakePersistence, FakeDataSource, and the
  # DataSource.Manager / StreamManager singletons.
  use TimelessCanvas.ConnCase, async: false

  alias TimelessCanvas.Canvas
  alias TimelessCanvas.Canvas.Serializer
  alias TimelessCanvas.CanvasPoller
  alias TimelessCanvas.DataQueries
  alias TimelessCanvas.DataSource.Manager
  alias TimelessCanvas.StreamManager
  alias TimelessCanvas.Test.FakeStreamBackend

  defp encode(canvas) do
    # Simulate the JSON round trip a DB-backed record goes through
    canvas |> Serializer.encode() |> Jason.encode!() |> Jason.decode!()
  end

  defp canvas_with_element(attrs) do
    {canvas, el} = Canvas.add_element(Canvas.new(snap_to_grid: false), attrs)
    {encode(canvas), el}
  end

  setup %{conn: conn} do
    user = test_user()
    {:ok, conn: log_in_user(conn, user), user: user}
  end

  describe "mount" do
    test "renders the canvas name and SVG container", %{conn: conn, user: user} do
      {data, _el} = canvas_with_element(%{x: 100.0, y: 100.0, label: "web-1", type: :server})

      record =
        FakePersistence.seed_canvas(%{name: "Prod Overview", user_id: user.id, data: data})

      {:ok, view, html} = live(conn, "/canvas/#{record.id}")

      assert html =~ "Prod Overview"
      assert has_element?(view, "#canvas-svg")
      assert has_element?(view, ~s([data-element-id="el-1"]))
      assert render(view) =~ "web-1"
    end

    test "empty data map falls back to an empty canvas", %{conn: conn, user: user} do
      record = FakePersistence.seed_canvas(%{name: "Blank", user_id: user.id, data: %{}})

      {:ok, view, html} = live(conn, "/canvas/#{record.id}")

      assert html =~ "Blank"
      assert has_element?(view, "#canvas-svg")
      refute has_element?(view, "[data-element-id]")
    end

    test "unknown canvas id redirects to the list with an error flash", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/canvas"}}} = live(conn, "/canvas/9999")
    end

    test "non-numeric canvas id redirects to the list", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/canvas"}}} = live(conn, "/canvas/not-a-number")
    end

    test "a non-owner can still mount with Noop auth", %{conn: conn, user: user} do
      {data, _el} = canvas_with_element(%{label: "shared-el"})

      record =
        FakePersistence.seed_canvas(%{name: "Shared Canvas", user_id: user.id + 1000, data: data})

      {:ok, view, html} = live(conn, "/canvas/#{record.id}")

      assert html =~ "Shared Canvas"
      assert render(view) =~ "shared-el"
      # Not the owner and Noop.admin? is false, so no Share button
      refute has_element?(view, ~s{button[phx-click="toggle_share"]})
    end

    test "owner sees the Share button", %{conn: conn, user: user} do
      record = FakePersistence.seed_canvas(%{user_id: user.id})

      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")

      assert has_element?(view, ~s{button[phx-click="toggle_share"]})
    end

    test "mount survives a metric_range error from the data source", %{conn: conn, user: user} do
      FakeDataSource.put(:metric_range, {:error, :backend_down})

      {canvas, _el} =
        Canvas.add_element(Canvas.new(), %{
          type: :graph,
          x: 100.0,
          y: 100.0,
          label: "cpu graph",
          meta: %{"host" => "web-1", "metric_name" => "cpu_usage"}
        })

      record = FakePersistence.seed_canvas(%{user_id: user.id, data: encode(canvas)})

      {:ok, view, html} = live(conn, "/canvas/#{record.id}")

      assert html =~ "cpu graph"
      assert has_element?(view, ~s([data-element-id="el-1"]))

      # The initial async load completes despite the backend error and
      # clears the loading badge without crashing the view.
      html = render_async(view)
      refute html =~ "Loading data"
      refute html =~ "Data load failed"
      assert html =~ "cpu graph"

      # Since Phase 4c the error is distinguishable from "no data": the
      # graph payload carries status "error" (rendered client-side as
      # "data unavailable").
      assert_push_event(view, "graph:data", %{id: "el-1", status: "error"}, 1_000)
    end

    test "programmed hosts are discoverable in place mode", %{conn: conn, user: user} do
      FakeDataSource.put(:list_hosts, ["host-a", "host-b"])
      record = FakePersistence.seed_canvas(%{user_id: user.id})

      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
      render_async(view)

      html =
        view
        |> element(~s{button[phx-value-mode="place"]})
        |> render_click()

      assert html =~ "host-a"
      refute html =~ "No hosts discovered"
    end
  end

  describe "async initial data load" do
    test "canvas structure renders immediately; data arrives via render_async", %{
      conn: conn,
      user: user
    } do
      now_ms = System.system_time(:millisecond)
      FakeDataSource.put(:metric_range, {:ok, [{now_ms - 60_000, 777.0}, {now_ms, 777.0}]})
      FakeDataSource.put(:list_hosts, ["host-a"])

      {canvas, _el} =
        Canvas.add_element(Canvas.new(), %{
          type: :graph,
          x: 100.0,
          y: 100.0,
          label: "cpu graph",
          meta: %{"host" => "web-1", "metric_name" => "cpu_usage"}
        })

      record = FakePersistence.seed_canvas(%{user_id: user.id, data: encode(canvas)})

      {:ok, view, html} = live(conn, "/canvas/#{record.id}")

      # Mount renders the structure with a loading badge and no data yet
      assert html =~ "cpu graph"
      assert has_element?(view, "#canvas-svg")
      assert html =~ "Loading data"
      refute html =~ "777"

      html = render_async(view)

      # Badge gone; the graph frame renders an empty phx-update="ignore"
      # container while the data itself arrives as a push_event — the
      # rendered HTML never contains the point values.
      refute html =~ "Loading data"
      refute html =~ "777"
      assert html =~ ~s(id="graph-dyn-el-1")
      assert html =~ ~s(phx-update="ignore")

      assert_push_event(view, "graph:data", %{
        id: "el-1",
        kind: "compact",
        value: "777",
        points: points,
        raw: [[_, 777.0], [_, 777.0]]
      })

      assert points =~ ","

      html = view |> element(~s{button[phx-value-mode="place"]}) |> render_click()
      assert html =~ "host-a"
      refute html =~ "No hosts discovered"
    end

    @tag capture_log: true
    test "a crashing initial load flags the failure without killing the view", %{
      conn: conn,
      user: user
    } do
      FakeDataSource.put(:time_range, fn -> raise "backend down" end)

      {data, _el} = canvas_with_element(%{label: "still-here"})
      record = FakePersistence.seed_canvas(%{user_id: user.id, data: data})

      {:ok, view, html} = live(conn, "/canvas/#{record.id}")
      assert html =~ "Loading data"

      html = render_async(view)

      refute html =~ "Loading data"
      assert html =~ "Data load failed"
      assert html =~ "still-here"

      # The view is still interactive after the failed load
      assert render(view) =~ "still-here"
    end

    test "a data range error from the backend does not crash the load", %{
      conn: conn,
      user: user
    } do
      FakeDataSource.put(:time_range, {:error, :backend_down})
      record = FakePersistence.seed_canvas(%{user_id: user.id})

      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
      html = render_async(view)

      refute html =~ "Loading data"
      refute html =~ "Data load failed"
    end

    test "a timeline scrub during the initial load is not stomped", %{conn: conn, user: user} do
      now = DateTime.utc_now()

      # Delay the initial load so the scrub lands while it is in flight;
      # the range is recent so the seed decision would be :live.
      FakeDataSource.put(:time_range, fn ->
        Process.sleep(200)
        {DateTime.add(now, -7200, :second), now}
      end)

      {data, _el} = canvas_with_element(%{label: "scrub-target"})
      record = FakePersistence.seed_canvas(%{user_id: user.id, data: data})

      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")

      # Scrub to ten minutes ago while the async load sleeps
      center_ms = System.system_time(:millisecond) - 600_000
      render_hook(view, "timeline:change", %{"time" => center_ms})

      scrubbed_time = :sys.get_state(view.pid).socket.assigns.timeline_time
      assert :sys.get_state(view.pid).socket.assigns.timeline_mode == :historical

      html = render_async(view, 1000)

      # The merge kept the user's historical position instead of resetting
      # to the live mount default.
      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.timeline_mode == :historical
      assert assigns.timeline_time == scrubbed_time
      refute html =~ "Loading data"
    end
  end

  describe "bounded host discovery" do
    test "a 1000-host universe never reaches the client wholesale", %{conn: conn, user: user} do
      hosts = for i <- 1..1000, do: "host-" <> String.pad_leading(Integer.to_string(i), 4, "0")
      FakeDataSource.put(:list_hosts, hosts)
      record = FakePersistence.seed_canvas(%{user_id: user.id})

      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
      render_async(view)

      html = view |> element(~s{button[phx-value-mode="place"]}) |> render_click()

      # Closed typeahead: only the bounded default (first host) appears as
      # the input placeholder; the rest of the universe is absent.
      assert html =~ "host-0001"
      refute html =~ "host-0100"
      refute html =~ "host-1000"

      # Opening runs one bounded query: exactly the cap of 50 suggestions
      # plus a truncation hint, never the full list.
      html = view |> element(~s{input[name="ta_search"]}) |> render_focus()

      assert html =~ "host-0050"
      refute html =~ "host-0051"
      assert html =~ "keep typing to narrow"
      assert count_occurrences(html, ~s(phx-click="ta:select")) == 50
    end

    test "ta:filter narrows via a bounded server-side query and pick still works", %{
      conn: conn,
      user: user
    } do
      hosts = for i <- 1..1000, do: "host-" <> String.pad_leading(Integer.to_string(i), 4, "0")
      FakeDataSource.put(:list_hosts, hosts)
      record = FakePersistence.seed_canvas(%{user_id: user.id})

      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
      render_async(view)
      view |> element(~s{button[phx-value-mode="place"]}) |> render_click()
      view |> element(~s{input[name="ta_search"]}) |> render_focus()

      html =
        view
        |> element(~s{input[name="ta_search"]})
        |> render_keyup(%{"value" => "host-0777"})

      assert count_occurrences(html, ~s(phx-click="ta:select")) == 1
      assert html =~ "host-0777"
      refute html =~ "host-0002"
      refute html =~ "keep typing to narrow"

      # Selecting a suggestion goes through the existing pick flow
      html = view |> element(~s{button[phx-value-value="host-0777"]}) |> render_click()

      assert html =~ ~s(placeholder="host-0777")
      refute html =~ ~s(phx-click="ta:select")
    end
  end

  describe "bounded series discovery" do
    test "series UI is grouped by metric, capped, hinted, and filterable", %{
      conn: conn,
      user: user
    } do
      # 240 programmed series across 3 metrics; the 200 cap keeps
      # alpha(80) + beta(80) + gamma(40).
      series =
        for metric <- ["alpha_metric", "beta_metric", "gamma_metric"],
            i <- 1..80,
            do: {metric, %{"idx" => "#{i}"}}

      FakeDataSource.put(:list_series_for_host, series)

      {data, el} =
        canvas_with_element(%{
          x: 100.0,
          y: 100.0,
          label: "web-1",
          type: :server,
          meta: %{"host" => "web-1"}
        })

      record = FakePersistence.seed_canvas(%{user_id: user.id, data: data})
      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")

      html = render_hook(view, "element:select", %{"id" => el.id})

      # Grouped: one Add Elements button per metric, not one per series
      assert count_occurrences(html, ~s(phx-click="place_series_graph")) == 3
      assert html =~ "alpha_metric"
      assert html =~ "gamma_metric"
      assert html =~ "showing first 200 series"

      # series:filter re-runs the bounded query with the typed filter
      html =
        view
        |> element(~s{input[name="series_filter"]})
        |> render_keyup(%{"value" => "beta"})

      assert count_occurrences(html, ~s(phx-click="place_series_graph")) == 1
      assert html =~ "beta_metric"
      refute html =~ "alpha_metric"
      refute html =~ "showing first 200 series"
    end

    test "graph series options and matching list come from the grouped structure", %{
      conn: conn,
      user: user
    } do
      FakeDataSource.put(:list_series_for_host, [
        {"cpu_usage", %{"core" => "0", "host" => "web-1"}},
        {"cpu_usage", %{"core" => "1", "host" => "web-1"}},
        {"mem_usage", %{"kind" => "rss", "host" => "web-1"}}
      ])

      {data, el} =
        canvas_with_element(%{
          x: 100.0,
          y: 100.0,
          label: "cpu graph",
          type: :graph,
          meta: %{"host" => "web-1", "metric_name" => "cpu_usage"}
        })

      record = FakePersistence.seed_canvas(%{user_id: user.id, data: data})
      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")

      html = render_hook(view, "element:select", %{"id" => el.id})

      assert html =~ "Matching Series"
      assert html =~ "Any series"
      assert html =~ "core=0"
      assert html =~ "core=1"
      assert html =~ "mem_usage"
      refute html =~ "showing first 200 series"
    end
  end

  defp count_occurrences(html, needle) do
    length(String.split(html, needle)) - 1
  end

  describe "shared canvas poller" do
    test "two viewers of one canvas both receive poller graph pushes", %{conn: conn, user: user} do
      # The poller reads :poll_interval from the data_source config at
      # start; shrink it for this test and restore afterwards.
      ds_config = Application.get_env(:timeless_canvas, :data_source)

      Application.put_env(
        :timeless_canvas,
        :data_source,
        Keyword.put(ds_config, :poll_interval, 60)
      )

      on_exit(fn -> Application.put_env(:timeless_canvas, :data_source, ds_config) end)

      now_ms = System.system_time(:millisecond)
      FakeDataSource.put(:metric_range, {:ok, [{now_ms - 60_000, 777.0}, {now_ms, 777.0}]})

      {canvas, _el} =
        Canvas.add_element(Canvas.new(), %{
          type: :graph,
          x: 100.0,
          y: 100.0,
          label: "cpu graph",
          meta: %{"host" => "web-1", "metric_name" => "cpu_usage"}
        })

      record = FakePersistence.seed_canvas(%{user_id: user.id, data: encode(canvas)})

      # A slow poller for this canvas id may linger from an earlier test
      # (FakePersistence ids restart at 1); replace it with a fast one.
      stop_poller(record.id)
      on_exit(fn -> stop_poller(record.id) end)

      {:ok, view_a, _html} = live(conn, "/canvas/#{record.id}")
      {:ok, view_b, _html} = live(log_in_user(build_conn(), user), "/canvas/#{record.id}")
      render_async(view_a)
      render_async(view_b)

      assert_push_event(view_a, "graph:data", %{id: "el-1", value: "777"}, 1_000)
      assert_push_event(view_b, "graph:data", %{id: "el-1", value: "777"}, 1_000)

      graph_html_before = view_a |> element(~s([data-element-id="el-1"])) |> render()
      refute graph_html_before =~ "777"

      # New live data: one poller tick fans the diff out to both views
      # as push_events.
      FakeDataSource.put(:metric_range, {:ok, [{now_ms - 60_000, 888.0}, {now_ms, 888.0}]})

      assert_push_event(view_a, "graph:data", %{id: "el-1", value: "888"}, 2_000)
      assert_push_event(view_b, "graph:data", %{id: "el-1", value: "888"}, 2_000)

      # Render-path regression: the data tick reached the client purely
      # as a push — the rendered graph markup (including the ignored
      # container) is byte-for-byte unchanged.
      assert view_a |> element(~s([data-element-id="el-1"])) |> render() ==
               graph_html_before
    end

    test "status broadcasts on one canvas's topic do not reach another canvas", %{
      conn: conn,
      user: user
    } do
      {data_a, el_a} = canvas_with_element(%{x: 100.0, y: 100.0, label: "a-el", type: :server})
      {data_b, _el_b} = canvas_with_element(%{x: 100.0, y: 100.0, label: "b-el", type: :server})

      record_a = FakePersistence.seed_canvas(%{name: "A", user_id: user.id, data: data_a})
      record_b = FakePersistence.seed_canvas(%{name: "B", user_id: user.id, data: data_b})

      {:ok, view_a, _html} = live(conn, "/canvas/#{record_a.id}")
      {:ok, view_b, _html} = live(log_in_user(build_conn(), user), "/canvas/#{record_b.id}")

      refute render(view_a) =~ "canvas-element__status--error"
      refute render(view_b) =~ "canvas-element__status--error"

      # Both canvases contain an element with the same id (el-1), so a
      # leaked broadcast would flip canvas B's element too.
      Phoenix.PubSub.broadcast(
        TimelessCanvas.TestPubSub,
        Manager.status_topic(record_a.id),
        {:element_status, el_a.id, :error}
      )

      assert eventually(fn -> render(view_a) =~ "canvas-element__status--error" end)
      refute render(view_b) =~ "canvas-element__status--error"
    end
  end

  defp stop_poller(canvas_id) do
    case CanvasPoller.whereis(canvas_id) do
      nil ->
        :ok

      pid ->
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end

        wait_until_unregistered(canvas_id, 50)
    end
  end

  defp wait_until_unregistered(_canvas_id, 0), do: :ok

  defp wait_until_unregistered(canvas_id, tries) do
    if CanvasPoller.whereis(canvas_id) do
      Process.sleep(10)
      wait_until_unregistered(canvas_id, tries - 1)
    else
      :ok
    end
  end

  defp eventually(fun, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) > deadline ->
        false

      true ->
        Process.sleep(25)
        do_eventually(fun, deadline)
    end
  end

  describe "client-side graph pushes" do
    defp seed_graph_canvas(user, value) do
      now_ms = System.system_time(:millisecond)
      FakeDataSource.put(:metric_range, {:ok, [{now_ms - 60_000, value}, {now_ms, value}]})

      {canvas, el} =
        Canvas.add_element(Canvas.new(), %{
          type: :graph,
          x: 100.0,
          y: 100.0,
          label: "cpu graph",
          meta: %{"host" => "web-1", "metric_name" => "cpu_usage"}
        })

      record = FakePersistence.seed_canvas(%{user_id: user.id, data: encode(canvas)})
      {record, el, now_ms}
    end

    test "a timeline scrub re-pushes graph data", %{conn: conn, user: user} do
      {record, el, now_ms} = seed_graph_canvas(user, 111.0)

      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
      render_async(view)
      assert_push_event(view, "graph:data", %{id: "el-1", value: "111"}, 1_000)

      # Different data at the scrubbed time
      FakeDataSource.put(
        :metric_range,
        {:ok, [{now_ms - 660_000, 222.0}, {now_ms - 600_000, 222.0}]}
      )

      render_hook(view, "timeline:change", %{"time" => now_ms - 600_000})

      assert_push_event(view, "graph:data", %{id: id, kind: "compact", value: "222"})
      assert id == el.id
    end

    test "expanding a graph pushes graph:expanded; collapsing restores graph:data", %{
      conn: conn,
      user: user
    } do
      {record, _el, _now_ms} = seed_graph_canvas(user, 333.0)

      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
      render_async(view)
      assert_push_event(view, "graph:data", %{id: "el-1", value: "333"}, 1_000)

      html = render_hook(view, "element:dblclick", %{"id" => "el-1"})
      assert html =~ ~s(id="graph-dyn-el-1-expanded")

      assert_push_event(view, "graph:expanded", %{
        id: "el-1",
        kind: "expanded",
        value: "333",
        points: points,
        area: area,
        raw: raw
      })

      assert points =~ ","
      assert area =~ ","
      assert [[_, 333.0], [_, 333.0]] = raw

      html = render_hook(view, "element:dblclick", %{"id" => "el-1"})
      refute html =~ "graph-dyn-el-1-expanded"
      assert_push_event(view, "graph:data", %{id: "el-1", kind: "compact", value: "333"})
    end

    test "graph:resync re-pushes the full snapshot", %{conn: conn, user: user} do
      {record, _el, _now_ms} = seed_graph_canvas(user, 444.0)

      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
      render_async(view)
      assert_push_event(view, "graph:data", %{id: "el-1", value: "444"}, 1_000)

      # The hook sends graph:resync from reconnected(); the server must
      # answer with a full snapshot even though nothing changed.
      render_hook(view, "graph:resync", %{})

      assert_push_event(view, "graph:data", %{id: "el-1", value: "444"})
    end
  end

  describe "stream entry popovers" do
    defp seed_log_stream_canvas(user) do
      {canvas, el} =
        Canvas.add_element(Canvas.new(snap_to_grid: false), %{
          type: :log_stream,
          x: 100.0,
          y: 100.0,
          label: "logs",
          meta: %{}
        })

      record = FakePersistence.seed_canvas(%{user_id: user.id, data: encode(canvas)})
      {record, el}
    end

    defp log_entry(message, level \\ :info) do
      DataQueries.put_entry_id(%{
        timestamp: System.system_time(:millisecond),
        level: level,
        message: message,
        metadata: %{}
      })
    end

    defp prepend_entry(canvas_id, element_id, entry) do
      Phoenix.PubSub.broadcast(
        TimelessCanvas.TestPubSub,
        StreamManager.stream_topic(canvas_id),
        {:stream_entries, element_id, [entry]}
      )
    end

    defp popover_message(view) do
      case :sys.get_state(view.pid).socket.assigns.stream_popover do
        %{entry: entry} -> entry.message
        nil -> nil
      end
    end

    test "rows carry entry ids and clicks resolve by id, surviving live prepends", %{
      conn: conn,
      user: user
    } do
      {record, el} = seed_log_stream_canvas(user)

      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
      render_async(view)

      first = log_entry("first-entry")
      prepend_entry(record.id, el.id, first)

      html = render(view)
      assert html =~ "first-entry"
      assert html =~ ~s(data-entry-id="#{first.id}")
      refute html =~ "data-stream-entry"

      html =
        render_hook(view, "stream:entry_click", %{
          "element_id" => el.id,
          "entry_id" => first.id
        })

      assert html =~ "stream-popover"
      assert popover_message(view) == "first-entry"

      # A live prepend shifts every row index; the id-based lookup must
      # still resolve the originally clicked entry (the old index-based
      # code would have shown "second-entry" here).
      second = log_entry("second-entry", :error)
      prepend_entry(record.id, el.id, second)
      assert render(view) =~ "second-entry"

      render_hook(view, "stream:entry_click", %{
        "element_id" => el.id,
        "entry_id" => first.id
      })

      assert popover_message(view) == "first-entry"
    end

    test "clicking an unknown entry id is a no-op", %{conn: conn, user: user} do
      {record, el} = seed_log_stream_canvas(user)

      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
      render_async(view)

      prepend_entry(record.id, el.id, log_entry("only-entry"))
      render(view)

      render_hook(view, "stream:entry_click", %{
        "element_id" => el.id,
        "entry_id" => 123_456_789
      })

      assert popover_message(view) == nil
      refute render(view) =~ "stream-popover"
    end
  end

  describe "stream registration and viewbox fast path" do
    defp with_fake_stream_backends do
      previous = Application.get_env(:timeless_canvas, :stream_backends)

      Application.put_env(:timeless_canvas, :stream_backends,
        log: FakeStreamBackend,
        trace: FakeStreamBackend
      )

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:timeless_canvas, :stream_backends)
          value -> Application.put_env(:timeless_canvas, :stream_backends, value)
        end
      end)

      FakeStreamBackend.reset()
      :ok
    end

    defp seed_registered_stream_canvas(user) do
      {canvas, el} =
        Canvas.add_element(Canvas.new(snap_to_grid: false), %{
          type: :log_stream,
          x: 100.0,
          y: 100.0,
          label: "logs",
          meta: %{"host" => "web-1"}
        })

      record = FakePersistence.seed_canvas(%{user_id: user.id, data: encode(canvas)})
      on_exit(fn -> StreamManager.unregister_stream(el.id) end)
      {record, el}
    end

    test "canvas:pan changes only the viewbox: no re-registration, no graph push", %{
      conn: conn,
      user: user
    } do
      with_fake_stream_backends()
      {record, _el} = seed_registered_stream_canvas(user)

      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
      render_async(view)
      assert eventually(fn -> FakeStreamBackend.subscribe_count() == 1 end)

      vb_before = :sys.get_state(view.pid).socket.assigns.canvas.view_box
      fingerprint_before = :sys.get_state(view.pid).socket.assigns.registration_fingerprint

      render_hook(view, "canvas:pan", %{"dx" => 25, "dy" => -10})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.canvas.view_box.min_x == vb_before.min_x + 25
      assert assigns.canvas.view_box.min_y == vb_before.min_y - 10
      assert assigns.registration_fingerprint == fingerprint_before

      # No backend re-subscription and no graph payload push from the pan.
      Process.sleep(50)
      assert FakeStreamBackend.subscribe_count() == 1
      refute_push_event(view, "graph:data", %{}, 0)
    end

    test "geometry-only mutations skip re-registration; meta changes re-register", %{
      conn: conn,
      user: user
    } do
      with_fake_stream_backends()
      {record, el} = seed_registered_stream_canvas(user)

      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
      render_async(view)
      assert eventually(fn -> FakeStreamBackend.subscribe_count() == 1 end)

      # A move goes through push_canvas but leaves the registration
      # fingerprint ({type, meta} per element) unchanged.
      render_hook(view, "element:move", %{"id" => el.id, "dx" => 30, "dy" => 0})
      Process.sleep(50)
      assert FakeStreamBackend.subscribe_count() == 1

      # A meta change that alters the backend opts must re-subscribe.
      # ("level" rather than "host": decode derives a literal host *pin*
      # from meta, so a host meta edit does not change the resolved host.)
      render_hook(view, "property:update_meta", %{"element_id" => el.id, "level" => "error"})
      assert eventually(fn -> FakeStreamBackend.subscribe_count() == 2 end)

      # Re-registration replaced, not duplicated, the subscription: the
      # opts now carry the level filter.
      assert eventually(fn ->
               live_subscriber_opts =
                 for {pid, opts} <- FakeStreamBackend.subscribers(), Process.alive?(pid), do: opts

               live_subscriber_opts == [[level: :error, metadata: %{"host" => "web-1"}]]
             end)
    end

    test "live entries render end to end through the batched path", %{conn: conn, user: user} do
      with_fake_stream_backends()
      Application.put_env(:timeless_canvas, :stream_batch_ms, 20)
      on_exit(fn -> Application.delete_env(:timeless_canvas, :stream_batch_ms) end)

      {record, _el} = seed_registered_stream_canvas(user)

      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
      render_async(view)
      assert eventually(fn -> FakeStreamBackend.subscribe_count() == 1 end)

      FakeStreamBackend.emit_log(%{
        timestamp: System.system_time(:millisecond),
        level: :info,
        message: "live-batched-entry",
        metadata: %{}
      })

      assert eventually(fn -> render(view) =~ "live-batched-entry" end)
    end
  end

  describe "element placement" do
    test "placing a rect via canvas:click adds it to the rendered SVG", %{
      conn: conn,
      user: user
    } do
      record = FakePersistence.seed_canvas(%{user_id: user.id})
      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")

      refute has_element?(view, "[data-element-id]")

      view |> element(~s{button[phx-value-mode="place"]}) |> render_click()
      view |> element(~s{button[phx-value-kind="rect"]}) |> render_click()

      html =
        view
        |> element("#canvas-svg")
        |> render_hook("canvas:click", %{"x" => 100, "y" => 100})

      assert html =~ "Rect 1"
      assert has_element?(view, ~s([data-element-id="el-1"]))
    end
  end

  describe "host placement semantics" do
    # Placing a host binds the literal chosen host — never the $host
    # variable. Variable binding is an explicit user opt-in via the
    # properties panel.
    test "placing a host pins the literal host and creates no variable", %{
      conn: conn,
      user: user
    } do
      FakeDataSource.put(:list_hosts, ["ohm", "watt"])
      record = FakePersistence.seed_canvas(%{user_id: user.id})

      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
      render_async(view)

      view |> element(~s{button[phx-value-mode="place"]}) |> render_click()
      view |> element(~s{input[name="ta_search"]}) |> render_focus()
      view |> element(~s{button[phx-value-value="ohm"]}) |> render_click()

      html =
        view
        |> element("#canvas-svg")
        |> render_hook("canvas:click", %{"x" => 100, "y" => 100})

      assert html =~ "ohm"
      refute html =~ "$host"

      state = :sys.get_state(view.pid)
      [{_id, el}] = Map.to_list(state.socket.assigns.canvas.elements)
      assert el.label == "ohm"
      assert el.meta["host"] == "ohm"
      assert el.pins["host"] == %{"mode" => "literal", "value" => "ohm"}
      refute Map.has_key?(state.socket.assigns.canvas.variables, "host")
      assert state.socket.assigns.resolved_elements[el.id].meta["host"] == "ohm"
    end
  end

  describe "meta edits vs pins" do
    # Serializer.decode derives a pin for host/ifname from meta, and pins
    # override meta at resolution — so a properties-panel host edit must
    # update the pin too, or it is silently inert after any reload.
    test "editing host in the properties panel updates the resolved host", %{
      conn: conn,
      user: user
    } do
      {data, el} =
        canvas_with_element(%{
          x: 100.0,
          y: 100.0,
          label: "pinned",
          type: :server,
          meta: %{"host" => "host-a"}
        })

      record = FakePersistence.seed_canvas(%{user_id: user.id, data: data})
      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")

      # Decode derived a literal pin for host-a
      state = :sys.get_state(view.pid)
      assert state.socket.assigns.resolved_elements[el.id].meta["host"] == "host-a"

      render_hook(view, "property:update_meta", %{"element_id" => el.id, "host" => "host-b"})

      state = :sys.get_state(view.pid)
      assert state.socket.assigns.canvas.elements[el.id].pins["host"]["value"] == "host-b"
      assert state.socket.assigns.resolved_elements[el.id].meta["host"] == "host-b"
    end
  end

  describe "icon rendering safety" do
    test "an unknown icon renders without crashing the view", %{conn: conn, user: user} do
      {data, el} =
        canvas_with_element(%{
          x: 100.0,
          y: 100.0,
          label: "bad-icon",
          type: :server,
          meta: %{"host" => "host-a", "icon" => "heroicons:no-such-icon-xyz"}
        })

      record = FakePersistence.seed_canvas(%{user_id: user.id, data: data})

      {view, html} =
        ExUnit.CaptureLog.with_log(fn ->
          {:ok, view, html} = live(conn, "/canvas/#{record.id}")
          {view, html}
        end)
        |> then(fn {{view, html}, _log} -> {view, html} end)

      assert html =~ "bad-icon"
      assert has_element?(view, ~s([data-element-id="#{el.id}"]))
      assert Process.alive?(view.pid)
    end
  end

  describe "element manipulation" do
    test "element:move updates the rendered position", %{conn: conn, user: user} do
      {data, el} = canvas_with_element(%{x: 100.0, y: 100.0, label: "mover"})
      record = FakePersistence.seed_canvas(%{user_id: user.id, data: data})

      {:ok, view, html} = live(conn, "/canvas/#{record.id}")
      assert html =~ ~s(x="100.0")

      moved_html =
        view
        |> element("#canvas-svg")
        |> render_hook("element:move", %{"id" => el.id, "dx" => 41, "dy" => 0})

      assert moved_html =~ ~s(x="141.0")
      refute moved_html =~ ~s(x="100.0")
    end

    test "delete removes the element and undo restores it in the rendered view", %{
      conn: conn,
      user: user
    } do
      {data, el} = canvas_with_element(%{x: 100.0, y: 100.0, label: "keep-me"})
      record = FakePersistence.seed_canvas(%{user_id: user.id, data: data})

      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")

      render_hook(view, "element:select", %{"id" => el.id})
      html = view |> element(~s{button[phx-click="delete_selected"]}) |> render_click()

      refute html =~ "keep-me"
      refute has_element?(view, ~s([data-element-id="#{el.id}"]))

      html = view |> element(~s{button[phx-click="canvas:undo"]}) |> render_click()

      assert html =~ "keep-me"
      assert has_element?(view, ~s([data-element-id="#{el.id}"]))
    end

    test "redo re-applies an undone delete", %{conn: conn, user: user} do
      {data, el} = canvas_with_element(%{x: 100.0, y: 100.0, label: "flip-flop"})
      record = FakePersistence.seed_canvas(%{user_id: user.id, data: data})

      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")

      render_hook(view, "element:select", %{"id" => el.id})
      view |> element(~s{button[phx-click="delete_selected"]}) |> render_click()
      view |> element(~s{button[phx-click="canvas:undo"]}) |> render_click()
      html = view |> element(~s{button[phx-click="canvas:redo"]}) |> render_click()

      refute html =~ "flip-flop"
      refute has_element?(view, ~s([data-element-id="#{el.id}"]))
    end

    test "canvas:save persists the canvas through the persistence adapter", %{
      conn: conn,
      user: user
    } do
      {data, _el} = canvas_with_element(%{label: "persist-me"})
      record = FakePersistence.seed_canvas(%{user_id: user.id, data: data})

      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")

      render_hook(view, "canvas:save", %{})

      {:ok, saved} = FakePersistence.get_canvas(record.id)
      assert %{"version" => 2, "elements" => elements} = saved.data
      assert elements["el-1"][:label] == "persist-me" or elements["el-1"]["label"] == "persist-me"
    end
  end

  defp with_fast_autosave(ms \\ 20, retry_ms \\ 40) do
    Application.put_env(:timeless_canvas, :autosave_ms, ms)
    Application.put_env(:timeless_canvas, :autosave_retry_ms, retry_ms)

    on_exit(fn ->
      Application.delete_env(:timeless_canvas, :autosave_ms)
      Application.delete_env(:timeless_canvas, :autosave_retry_ms)
    end)
  end

  defp saved_elements(canvas_id) do
    {:ok, saved} = FakePersistence.get_canvas(canvas_id)
    saved.data["elements"] || %{}
  end

  describe "autosave and save state" do
    test "an edit marks the canvas dirty and the autosave persists it as saved", %{
      conn: conn,
      user: user
    } do
      with_fast_autosave()
      {data, el} = canvas_with_element(%{x: 100.0, y: 100.0, label: "dirty-me"})
      record = FakePersistence.seed_canvas(%{user_id: user.id, data: data})

      {:ok, view, html} = live(conn, "/canvas/#{record.id}")
      assert html =~ "Saved"
      refute html =~ "Unsaved changes"

      html = render_hook(view, "element:move", %{"id" => el.id, "dx" => 41, "dy" => 0})
      assert html =~ "Unsaved changes"

      assert eventually(fn -> saved_elements(record.id)[el.id]["x"] == 141.0 end)

      assert eventually(fn ->
               render(view) =~ "Saved" and !(render(view) =~ "Unsaved changes")
             end)
    end

    @tag capture_log: true
    test "a failing autosave shows the error state and retries until the store recovers", %{
      conn: conn,
      user: user
    } do
      with_fast_autosave()
      {data, el} = canvas_with_element(%{x: 100.0, y: 100.0, label: "retry-me"})
      record = FakePersistence.seed_canvas(%{user_id: user.id, data: data})

      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")

      FakePersistence.fail_update_canvas_data({:error, :db_down})
      render_hook(view, "element:move", %{"id" => el.id, "dx" => 41, "dy" => 0})

      assert eventually(fn -> render(view) =~ "Save failed — retrying" end)
      assert saved_elements(record.id)[el.id]["x"] == 100.0

      # The store recovers; a scheduled retry self-heals without any
      # further user interaction.
      FakePersistence.fail_update_canvas_data(nil)

      assert eventually(fn -> saved_elements(record.id)[el.id]["x"] == 141.0 end)
      assert eventually(fn -> render(view) =~ "Saved" and !(render(view) =~ "Save failed") end)
    end

    @tag capture_log: true
    test "autosave stops retrying after 5 consecutive failures; the next edit re-arms it", %{
      conn: conn,
      user: user
    } do
      with_fast_autosave(10, 10)
      {data, el} = canvas_with_element(%{x: 100.0, y: 100.0, label: "give-up"})
      record = FakePersistence.seed_canvas(%{user_id: user.id, data: data})

      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")

      FakePersistence.fail_update_canvas_data({:error, :db_down})
      render_hook(view, "element:move", %{"id" => el.id, "dx" => 41, "dy" => 0})

      assert eventually(fn ->
               :sys.get_state(view.pid).socket.assigns.autosave_failures == 5
             end)

      # Gave up: error state without a pending retry timer.
      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.save_state == :error
      assert assigns.autosave_ref == nil
      assert render(view) =~ "Save failed"
      refute render(view) =~ "retrying"

      # A new edit resets the failure budget and re-arms autosave.
      FakePersistence.fail_update_canvas_data(nil)
      html = render_hook(view, "element:move", %{"id" => el.id, "dx" => 1, "dy" => 0})
      assert html =~ "Unsaved changes"
      assert eventually(fn -> saved_elements(record.id)[el.id]["x"] == 142.0 end)
    end

    @tag capture_log: true
    test "manual canvas:save updates the save state in both directions", %{
      conn: conn,
      user: user
    } do
      with_fast_autosave()
      {data, _el} = canvas_with_element(%{label: "manual-save"})
      record = FakePersistence.seed_canvas(%{user_id: user.id, data: data})

      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")

      FakePersistence.fail_update_canvas_data({:error, :db_down})
      html = render_hook(view, "canvas:save", %{})
      assert html =~ "Save failed — retrying"

      FakePersistence.fail_update_canvas_data(nil)
      html = render_hook(view, "canvas:save", %{})
      assert html =~ "Saved"
      refute html =~ "Save failed"
    end
  end

  describe "undo/redo persistence" do
    test "undo and redo both autosave the resulting state", %{conn: conn, user: user} do
      with_fast_autosave()
      {data, el} = canvas_with_element(%{x: 100.0, y: 100.0, label: "undo-me"})
      record = FakePersistence.seed_canvas(%{user_id: user.id, data: data})

      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")

      render_hook(view, "element:select", %{"id" => el.id})
      view |> element(~s{button[phx-click="delete_selected"]}) |> render_click()
      assert eventually(fn -> saved_elements(record.id) == %{} end)

      # The data-loss bug: an undone delete must reach the store too.
      view |> element(~s{button[phx-click="canvas:undo"]}) |> render_click()
      assert eventually(fn -> saved_elements(record.id)[el.id]["label"] == "undo-me" end)

      view |> element(~s{button[phx-click="canvas:redo"]}) |> render_click()
      assert eventually(fn -> saved_elements(record.id) == %{} end)
    end

    test "undoing a stream element delete re-registers its subscription", %{
      conn: conn,
      user: user
    } do
      with_fast_autosave()
      with_fake_stream_backends()
      {record, el} = seed_registered_stream_canvas(user)

      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
      render_async(view)
      assert eventually(fn -> FakeStreamBackend.subscribe_count() == 1 end)

      render_hook(view, "element:select", %{"id" => el.id})
      view |> element(~s{button[phx-click="delete_selected"]}) |> render_click()

      # Undo restores the element; the fingerprint diff must re-register
      # the stream subscription (a second backend subscribe).
      view |> element(~s{button[phx-click="canvas:undo"]}) |> render_click()
      assert eventually(fn -> FakeStreamBackend.subscribe_count() == 2 end)

      assert eventually(fn ->
               Enum.any?(FakeStreamBackend.subscribers(), fn {pid, _opts} ->
                 Process.alive?(pid)
               end)
             end)
    end
  end

  describe "stored-data decode protection" do
    @corrupt_data %{"version" => 999, "elements" => "garbage"}

    test "fresh %{} data mounts editable with no warning", %{conn: conn, user: user} do
      record = FakePersistence.seed_canvas(%{user_id: user.id, data: %{}})

      {:ok, view, html} = live(conn, "/canvas/#{record.id}")

      refute html =~ "could not be read"
      assert html =~ "Saved"

      # Editing works: place a rect.
      view |> element(~s{button[phx-value-mode="place"]}) |> render_click()
      view |> element(~s{button[phx-value-kind="rect"]}) |> render_click()

      html =
        view
        |> element("#canvas-svg")
        |> render_hook("canvas:click", %{"x" => 100, "y" => 100})

      assert html =~ "Rect 1"
    end

    test "corrupt data shows the banner, denies edits, and never overwrites the blob", %{
      conn: conn,
      user: user
    } do
      with_fast_autosave()
      record = FakePersistence.seed_canvas(%{user_id: user.id, data: @corrupt_data})

      {:ok, view, html} =
        ExUnit.CaptureLog.with_log(fn -> live(conn, "/canvas/#{record.id}") end)
        |> then(fn {{:ok, view, html}, _log} -> {:ok, view, html} end)

      assert html =~ "could not be read"
      assert html =~ "Discard stored data and start fresh"

      # Edits are denied while the flag is set.
      view |> element(~s{button[phx-value-mode="place"]}) |> render_click()
      view |> element(~s{button[phx-value-kind="rect"]}) |> render_click()

      html =
        view
        |> element("#canvas-svg")
        |> render_hook("canvas:click", %{"x" => 100, "y" => 100})

      refute html =~ "Rect 1"
      refute has_element?(view, "[data-element-id]")

      # No autosave ever fires: the stored blob stays untouched.
      Process.sleep(80)
      {:ok, saved} = FakePersistence.get_canvas(record.id)
      assert saved.data == @corrupt_data
    end

    test "the discard button restores editability and persists a fresh canvas", %{
      conn: conn,
      user: user
    } do
      with_fast_autosave()
      record = FakePersistence.seed_canvas(%{user_id: user.id, data: @corrupt_data})

      {:ok, view, _html} =
        ExUnit.CaptureLog.with_log(fn -> live(conn, "/canvas/#{record.id}") end)
        |> then(fn {{:ok, view, html}, _log} -> {:ok, view, html} end)

      html = view |> element(".canvas-decode-warning__btn") |> render_click()
      refute html =~ "could not be read"

      # The fresh (empty) canvas is persisted over the unreadable blob.
      assert eventually(fn ->
               match?(%{"version" => 2}, elem(FakePersistence.get_canvas(record.id), 1).data)
             end)

      # Editing works again and persists.
      view |> element(~s{button[phx-value-mode="place"]}) |> render_click()
      view |> element(~s{button[phx-value-kind="rect"]}) |> render_click()

      html =
        view
        |> element("#canvas-svg")
        |> render_hook("canvas:click", %{"x" => 100, "y" => 100})

      assert html =~ "Rect 1"
      assert eventually(fn -> map_size(saved_elements(record.id)) == 1 end)
    end
  end

  describe "per-canvas element scoping and cleanup" do
    defp manager_registered?(canvas_id, element_id) do
      case :ets.lookup(:timeless_canvas_data_source, :elements) do
        [{:elements, elements}] -> Map.has_key?(elements, {canvas_id, element_id})
        _ -> false
      end
    end

    test "two canvases sharing an element id each get their own element's data", %{
      conn: conn,
      user: user
    } do
      now_ms = System.system_time(:millisecond)

      # Per-element canned data: the value depends on the element's host.
      FakeDataSource.put(:metric_range, fn element ->
        value = if element.meta["host"] == "host-a", do: 111.0, else: 222.0
        {:ok, [{now_ms - 60_000, value}, {now_ms, value}]}
      end)

      graph = fn host ->
        {canvas, _el} =
          Canvas.add_element(Canvas.new(), %{
            type: :graph,
            x: 100.0,
            y: 100.0,
            label: "#{host} graph",
            meta: %{"host" => host, "metric_name" => "cpu_usage"}
          })

        encode(canvas)
      end

      record_a = FakePersistence.seed_canvas(%{user_id: user.id, data: graph.("host-a")})
      record_b = FakePersistence.seed_canvas(%{user_id: user.id, data: graph.("host-b")})

      {:ok, view_a, _html} = live(conn, "/canvas/#{record_a.id}")
      {:ok, view_b, _html} = live(log_in_user(build_conn(), user), "/canvas/#{record_b.id}")
      render_async(view_a)
      render_async(view_b)

      # Both canvases contain "el-1", but each query resolves its own
      # canvas's element (the old registry collided on the bare id).
      assert_push_event(view_a, "graph:data", %{id: "el-1", value: "111"}, 1_000)
      assert_push_event(view_b, "graph:data", %{id: "el-1", value: "222"}, 1_000)
    end

    test "a closed viewer drops its canvas's registrations — unless another viewer remains", %{
      conn: conn,
      user: user
    } do
      Process.flag(:trap_exit, true)

      {data, el} = canvas_with_element(%{x: 100.0, y: 100.0, label: "leak-check", type: :server})
      record = FakePersistence.seed_canvas(%{user_id: user.id, data: data})

      {:ok, view_a, _html} = live(conn, "/canvas/#{record.id}")
      {:ok, view_b, _html} = live(log_in_user(build_conn(), user), "/canvas/#{record.id}")

      assert eventually(fn -> manager_registered?(record.id, el.id) end)

      # First viewer dies: the second keeps the registration alive.
      Process.exit(view_a.pid, :kill)
      Process.sleep(100)
      assert manager_registered?(record.id, el.id)

      # Last viewer dies: the canvas's registrations are dropped.
      Process.exit(view_b.pid, :kill)
      assert eventually(fn -> not manager_registered?(record.id, el.id) end)
    end
  end
end
