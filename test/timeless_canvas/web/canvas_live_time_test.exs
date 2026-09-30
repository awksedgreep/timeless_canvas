defmodule TimelessCanvas.Web.CanvasLiveTimeTest do
  # async: false — shares FakePersistence, FakeDataSource, and the
  # DataSource.Manager / StreamManager singletons.
  use TimelessCanvas.ConnCase, async: false

  alias TimelessCanvas.Canvas
  alias TimelessCanvas.Canvas.Serializer
  alias TimelessCanvas.DataQueries
  alias TimelessCanvas.StreamManager

  # 2026-09-29 21:44:05.250 UTC, which is 17:44:05 four hours west.
  @moment 1_790_718_245_250
  @west %{"zone" => "America/New_York", "offset_minutes" => -240}

  defp encode(canvas), do: canvas |> Serializer.encode() |> Jason.encode!() |> Jason.decode!()

  defp seed(user, elements) do
    canvas =
      Enum.reduce(elements, Canvas.new(snap_to_grid: false), fn attrs, canvas ->
        canvas |> Canvas.add_element(attrs) |> elem(0)
      end)

    FakePersistence.seed_canvas(%{user_id: user.id, data: encode(canvas)})
  end

  defp log_stream, do: %{type: :log_stream, x: 100.0, y: 100.0, label: "logs", meta: %{}}
  defp trace_stream, do: %{type: :trace_stream, x: 100.0, y: 300.0, label: "spans", meta: %{}}

  defp graph do
    %{type: :graph, label: "cpu", meta: %{"host" => "web-01", "metric_name" => "cpu_usage"}}
  end

  defp entry(timestamp, message) do
    DataQueries.put_entry_id(%{
      timestamp: timestamp,
      level: :info,
      message: message,
      metadata: %{}
    })
  end

  # The view merges what arrives on a message it sends itself, so one round
  # trip to it puts the merge ahead of the render that follows.
  defp prepend(view, canvas_id, element_id, entries) do
    Phoenix.PubSub.broadcast(
      TimelessCanvas.TestPubSub,
      StreamManager.stream_topic(canvas_id),
      {:stream_entries, element_id, entries}
    )

    :sys.get_state(view.pid)
    :ok
  end

  defp tz(view), do: :sys.get_state(view.pid).socket.assigns.tz

  setup %{conn: conn} do
    user = test_user()
    {:ok, conn: log_in_user(conn, user), user: user}
  end

  test "the clock is UTC until the browser says otherwise", %{conn: conn, user: user} do
    record = seed(user, [log_stream()])
    {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
    render_async(view)
    prepend(view, record.id, "el-1", [entry(@moment, "as it was")])

    assert tz(view) == %{zone: nil, offset: 0}
    assert render(view) =~ "21:44:05 [INFO] as it was"
  end

  test "log rows and their popover are written on the viewer's clock", %{
    conn: conn,
    user: user
  } do
    record = seed(user, [log_stream()])
    {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
    render_async(view)
    row = entry(@moment, "on my clock")
    prepend(view, record.id, "el-1", [row])

    html = render_hook(view, "client:timezone", @west)
    assert html =~ "17:44:05 [INFO] on my clock"
    refute html =~ "21:44:05"

    html =
      render_hook(view, "stream:entry_click", %{"element_id" => "el-1", "entry_id" => row.id})

    assert html =~ "17:44:05.250"
  end

  test "a popover reads a timestamp in the unit its row does", %{conn: conn, user: user} do
    record = seed(user, [log_stream()])
    {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
    render_async(view)

    for {timestamp, shown} <- [
          {div(@moment, 1000), "21:44:05.000"},
          {@moment, "21:44:05.250"},
          {@moment * 1_000 + 123, "21:44:05.250"},
          {@moment * 1_000_000 + 123_456, "21:44:05.250"}
        ] do
      row = entry(timestamp, "unit #{timestamp}")
      prepend(view, record.id, "el-1", [row])
      assert render(view) =~ "21:44:05 [INFO] unit #{timestamp}"

      html =
        render_hook(view, "stream:entry_click", %{"element_id" => "el-1", "entry_id" => row.id})

      assert html =~ shown
    end
  end

  test "trace rows are written on the viewer's clock", %{conn: conn, user: user} do
    record = seed(user, [trace_stream()])
    {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
    render_async(view)

    span =
      DataQueries.put_entry_id(%{
        timestamp: @moment * 1_000_000,
        trace_id: "abc",
        span_id: "def",
        name: "GET /",
        kind: :server,
        duration_ns: 1_000_000,
        status: :ok,
        status_message: nil,
        service: "web"
      })

    prepend(view, record.id, "el-1", [span])
    assert render(view) =~ "21:44:05"

    html = render_hook(view, "client:timezone", @west)
    assert html =~ "17:44:05"
    refute html =~ "21:44:05"
  end

  test "graph axis labels are made again on the viewer's clock", %{conn: conn, user: user} do
    FakeDataSource.put(:metric_range, {:ok, [{@moment, 2.0}, {@moment - 60_000, 1.0}]})
    record = seed(user, [graph()])
    {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
    render_async(view)

    assert_push_event(view, "graph:data", %{id: "el-1", x_labels: utc_labels}, 1_000)
    assert Enum.map(utc_labels, & &1.text) |> Enum.all?(&String.starts_with?(&1, "21:"))

    render_hook(view, "client:timezone", @west)

    assert_push_event(view, "graph:data", %{id: "el-1", x_labels: local_labels}, 1_000)
    assert Enum.map(local_labels, & &1.text) |> Enum.all?(&String.starts_with?(&1, "17:"))
    assert length(local_labels) == length(utc_labels)
  end

  test "the timeline's ends and its readout are on the viewer's clock", %{
    conn: conn,
    user: user
  } do
    record = seed(user, [graph()])
    {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
    render_async(view)

    # Scrub to a known moment; the window's centre is what is read out.
    render_hook(view, "timeline:change", %{"time" => @moment})
    assert render(view) =~ "Sep 29 21:44:05"

    html = render_hook(view, "client:timezone", @west)
    assert html =~ "Sep 29 17:44:05"
    refute html =~ "Sep 29 21:44:05"

    # Far enough east, the same moment is the next day.
    html = render_hook(view, "client:timezone", %{"zone" => nil, "offset_minutes" => 330})
    assert html =~ "Sep 30 03:14:05"
  end

  test "saying the same clock again pushes nothing", %{conn: conn, user: user} do
    FakeDataSource.put(:metric_range, {:ok, [{@moment, 2.0}]})
    record = seed(user, [graph()])
    {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
    render_async(view)
    assert_push_event(view, "graph:data", %{id: "el-1"}, 1_000)

    render_hook(view, "client:timezone", @west)
    assert_push_event(view, "graph:data", %{id: "el-1"}, 1_000)

    render_hook(view, "client:timezone", @west)
    refute_push_event(view, "graph:data", %{id: "el-1"}, 200)
  end

  test "a clock that makes no sense is UTC, and the view lives", %{conn: conn, user: user} do
    record = seed(user, [log_stream()])
    {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
    render_async(view)
    prepend(view, record.id, "el-1", [entry(@moment, "still here")])
    render_hook(view, "client:timezone", @west)

    for params <- [
          %{},
          %{"zone" => %{"a" => 1}, "offset_minutes" => "soon"},
          %{"zone" => "../../x", "offset_minutes" => 1.0e9},
          %{"offset_minutes" => 100_000_000}
        ] do
      html = render_hook(view, "client:timezone", params)
      assert tz(view) == %{zone: nil, offset: 0}
      assert html =~ "21:44:05 [INFO] still here"
      render_hook(view, "client:timezone", @west)
    end

    assert Process.alive?(view.pid)
  end

  test "a viewer who may not edit can still say what their clock is", %{conn: conn, user: user} do
    owner = user.id + 1000
    canvas = Canvas.new(snap_to_grid: false) |> Canvas.add_element(log_stream()) |> elem(0)
    record = FakePersistence.seed_canvas(%{user_id: owner, data: encode(canvas)})

    previous = Application.get_env(:timeless_canvas, :auth)
    Application.put_env(:timeless_canvas, :auth, TimelessCanvas.Test.DenyEditAuth)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:timeless_canvas, :auth, previous),
        else: Application.delete_env(:timeless_canvas, :auth)
    end)

    {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
    render_async(view)
    render_hook(view, "client:timezone", @west)

    assert tz(view).offset == -14_400
  end
end
