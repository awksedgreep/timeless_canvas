defmodule TimelessCanvas.Web.CanvasLiveUsabilityTest do
  # Phase 4c coverage: distinct error vs empty element states, the Go Live
  # button + historical readout, compact-graph title truncation, editor
  # presence, and the stale-write warning.
  #
  # async: false — shares FakePersistence, FakeDataSource, the
  # DataSource.Manager / StreamManager singletons, and the Presence tracker.
  use TimelessCanvas.ConnCase, async: false

  alias TimelessCanvas.Canvas
  alias TimelessCanvas.Canvas.Serializer
  alias TimelessCanvas.StreamManager
  alias TimelessCanvas.Test.FakeStreamBackend

  defp encode(canvas) do
    canvas |> Serializer.encode() |> Jason.encode!() |> Jason.decode!()
  end

  setup %{conn: conn} do
    user = test_user()
    {:ok, conn: log_in_user(conn, user), user: user}
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

  defp seed_graph_canvas(user, attrs \\ %{}) do
    {canvas, el} =
      Canvas.add_element(
        Canvas.new(),
        Map.merge(
          %{
            type: :graph,
            x: 100.0,
            y: 100.0,
            label: "cpu graph",
            meta: %{"host" => "web-1", "metric_name" => "cpu_usage"}
          },
          attrs
        )
      )

    record = FakePersistence.seed_canvas(%{user_id: user.id, data: encode(canvas)})
    {record, el}
  end

  describe "distinct error vs empty graph states" do
    test "a backend error pushes status error; a later success recovers to ok", %{
      conn: conn,
      user: user
    } do
      FakeDataSource.put(:metric_range, {:error, :backend_down})
      {record, _el} = seed_graph_canvas(user)

      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
      render_async(view)

      assert_push_event(
        view,
        "graph:data",
        %{id: "el-1", kind: "compact", status: "error", points: "", value: nil},
        1_000
      )

      # The backend recovers; a timeline-driven refresh replaces the
      # error state with real data — no special-case reset path needed.
      now_ms = System.system_time(:millisecond)

      FakeDataSource.put(
        :metric_range,
        {:ok, [{now_ms - 120_000, 555.0}, {now_ms - 60_000, 555.0}]}
      )

      render_hook(view, "timeline:change", %{"time" => now_ms - 60_000})

      assert_push_event(view, "graph:data", %{
        id: "el-1",
        status: "ok",
        value: "555",
        points: points
      })

      assert points =~ ","
    end

    test "an empty series pushes status empty (not error)", %{conn: conn, user: user} do
      # FakeDataSource default metric_range is {:ok, []}.
      {record, _el} = seed_graph_canvas(user)

      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
      render_async(view)

      assert_push_event(view, "graph:data", %{id: "el-1", status: "empty", value: nil}, 1_000)
    end

    test "an expanded graph carries the status through graph:expanded", %{
      conn: conn,
      user: user
    } do
      FakeDataSource.put(:metric_range, {:error, :backend_down})
      {record, _el} = seed_graph_canvas(user)

      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
      render_async(view)
      assert_push_event(view, "graph:data", %{id: "el-1", status: "error"}, 1_000)

      render_hook(view, "element:dblclick", %{"id" => "el-1"})

      assert_push_event(view, "graph:expanded", %{id: "el-1", kind: "expanded", status: "error"})
    end
  end

  describe "distinct error vs empty stream states" do
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

    defp seed_log_stream_canvas(user) do
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

    test "a log backend query error renders its own state and recovers", %{
      conn: conn,
      user: user
    } do
      with_fake_stream_backends()
      FakeStreamBackend.set_query_result({:error, :backend_down})
      {record, _el} = seed_log_stream_canvas(user)

      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
      html = render_async(view)

      assert html =~ "log backend unavailable"
      refute html =~ "Waiting for logs"

      # Backend comes back (empty window): the next historical fill
      # clears the error state back to the normal waiting state.
      FakeStreamBackend.set_query_result({:ok, %{entries: []}})
      now_ms = System.system_time(:millisecond)
      html = render_hook(view, "timeline:change", %{"time" => now_ms - 600_000})

      refute html =~ "log backend unavailable"
      assert html =~ "Waiting for logs"
    end

    test "a live entry also clears a prior stream error state", %{conn: conn, user: user} do
      with_fake_stream_backends()
      Application.put_env(:timeless_canvas, :stream_batch_ms, 20)
      on_exit(fn -> Application.delete_env(:timeless_canvas, :stream_batch_ms) end)

      FakeStreamBackend.set_query_result({:error, :backend_down})
      {record, _el} = seed_log_stream_canvas(user)

      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
      assert render_async(view) =~ "log backend unavailable"
      assert eventually(fn -> FakeStreamBackend.subscribe_count() == 1 end)

      FakeStreamBackend.emit_log(%{
        timestamp: System.system_time(:millisecond),
        level: :info,
        message: "stream-back-alive",
        metadata: %{}
      })

      assert eventually(fn -> render(view) =~ "stream-back-alive" end)
      refute render(view) =~ "log backend unavailable"
    end
  end

  describe "Go Live button and historical readout" do
    test "historical mode shows the readout + button; clicking returns to live", %{
      conn: conn,
      user: user
    } do
      {data, _el} =
        Canvas.add_element(Canvas.new(snap_to_grid: false), %{
          x: 100.0,
          y: 100.0,
          label: "web-1",
          type: :server
        })
        |> then(fn {canvas, el} -> {encode(canvas), el} end)

      record = FakePersistence.seed_canvas(%{user_id: user.id, data: data})

      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
      render_async(view)

      refute has_element?(view, ~s{button[phx-click="timeline:go_live"]})
      refute render(view) =~ "timeline-bar__readout"

      center_ms = System.system_time(:millisecond) - 600_000
      html = render_hook(view, "timeline:change", %{"time" => center_ms})

      assert has_element?(view, ~s{button[phx-click="timeline:go_live"]})
      assert html =~ "Go Live"
      assert html =~ "timeline-bar__readout"

      # The readout shows the viewed (window-center) time, formatted like
      # the drag bubble ("Jul 30 22:14:05" style).
      expected =
        center_ms
        |> DateTime.from_unix!(:millisecond)
        |> Calendar.strftime("%b %-d %H:%M")

      assert html =~ expected

      html = view |> element(~s{button[phx-click="timeline:go_live"]}) |> render_click()

      assert :sys.get_state(view.pid).socket.assigns.timeline_mode == :live
      refute html =~ "Go Live"
      refute html =~ "timeline-bar__readout"
    end
  end

  describe "compact graph title truncation" do
    test "long titles are ellipsized to leave room for the value text", %{
      conn: conn,
      user: user
    } do
      long_metric = String.duplicate("m", 80)
      {record, _el} = seed_graph_canvas(user, %{label: "", meta: %{"metric_name" => long_metric}})

      {:ok, _view, html} = live(conn, "/canvas/#{record.id}")

      # Default graph width 220, no icon: (220 - 4 - 56) / 4.8 → 33 chars
      # budget → 32 title chars + the ellipsis.
      refute html =~ long_metric
      assert html =~ String.duplicate("m", 32) <> "…"
      refute html =~ String.duplicate("m", 33)
    end
  end

  describe "editor presence" do
    test "two editors see each other's chips; a leaver's chip disappears", %{conn: conn} do
      Process.flag(:trap_exit, true)

      user_a = test_user(%{id: 991, username: "alice"})
      user_b = test_user(%{id: 992, username: "bob"})

      # A unique canvas id avoids presence bleed-through from earlier
      # tests (FakePersistence ids restart at 1 otherwise).
      record =
        FakePersistence.seed_canvas(%{
          id: System.unique_integer([:positive]) + 500_000,
          user_id: user_a.id
        })

      {:ok, view_a, _html} = live(log_in_user(conn, user_a), "/canvas/#{record.id}")
      refute render(view_a) =~ "Also viewing"

      {:ok, view_b, _html} = live(log_in_user(build_conn(), user_b), "/canvas/#{record.id}")

      # b's mount already sees alice; a learns about bob via the diff.
      assert render(view_b) =~ "alice"
      assert eventually(fn -> render(view_a) =~ "bob" end)
      assert render(view_a) =~ "Also viewing"
      refute render(view_a) =~ "alice"

      Process.exit(view_b.pid, :kill)

      assert eventually(fn -> not (render(view_a) =~ "bob") end)
      refute render(view_a) =~ "Also viewing"
    end
  end

  describe "stale-write warning" do
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

    @tag capture_log: true
    test "an external save between our writes raises the warning once", %{
      conn: conn,
      user: user
    } do
      with_fast_autosave()

      {canvas, el} =
        Canvas.add_element(Canvas.new(snap_to_grid: false), %{
          x: 100.0,
          y: 100.0,
          label: "contended"
        })

      record = FakePersistence.seed_canvas(%{user_id: user.id, data: encode(canvas)})

      {:ok, view, html} = live(conn, "/canvas/#{record.id}")
      refute html =~ "Another editor saved"

      # Another editor writes the record directly, bumping updated_at.
      {:ok, _} = FakePersistence.update_canvas_data(record.id, record.data)

      # Our next autosave detects the bump, warns, and still writes
      # (last-write-wins per agreed scope).
      render_hook(view, "element:move", %{"id" => el.id, "dx" => 41, "dy" => 0})
      assert eventually(fn -> render(view) =~ "Another editor saved changes" end)
      assert eventually(fn -> saved_elements(record.id)[el.id]["x"] == 141.0 end)

      # Dismiss; a further save with no external change raises no new warning.
      view |> element(".canvas-stale-warning__btn") |> render_click()
      refute render(view) =~ "Another editor saved"

      render_hook(view, "element:move", %{"id" => el.id, "dx" => 1, "dy" => 0})
      assert eventually(fn -> saved_elements(record.id)[el.id]["x"] == 142.0 end)
      refute render(view) =~ "Another editor saved"
    end
  end
end
