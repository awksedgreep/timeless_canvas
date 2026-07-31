defmodule TimelessCanvas.Web.CanvasLiveTest do
  # async: false — shares FakePersistence, FakeDataSource, and the
  # DataSource.Manager / StreamManager singletons.
  use TimelessCanvas.ConnCase, async: false

  alias TimelessCanvas.Canvas
  alias TimelessCanvas.Canvas.Serializer

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
      # NOTE (known issue, do not pin as correct): query errors currently
      # render identically to no-data, so we only assert that mount does not
      # crash.
      assert html =~ "cpu graph"
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

      # Badge gone, programmed graph data and hosts are in
      refute html =~ "Loading data"
      assert html =~ "777"

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
end
