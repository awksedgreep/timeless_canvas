defmodule TimelessCanvas.CanvasE2ETest do
  @moduledoc """
  Browser E2E suite (`mix test.e2e`, or `E2E=1 mix test --only e2e`).

  Each test seeds fakes on the Elixir side, then drives a real browser
  through one named flow in `test/e2e/flows.js` (see
  `TimelessCanvas.E2ECase.run_flow/2`). Engine selection is via
  `E2E_BROWSER` (chromium default; firefox/webkit need
  `npx playwright install <engine>` in test/e2e first).
  """

  use TimelessCanvas.E2ECase, async: false

  alias TimelessCanvas.StreamManager

  # --- Seed helpers ---

  defp seed(id, %Canvas{} = canvas, attrs \\ %{}) do
    FakePersistence.seed_canvas(
      Map.merge(%{id: id, user_id: e2e_user().id, data: encode(canvas)}, attrs)
    )
  end

  defp rect_canvas(positions) do
    Enum.reduce(positions, Canvas.new(snap_to_grid: false), fn {x, y}, canvas ->
      {canvas, _el} = Canvas.add_element(canvas, %{type: :rect, x: x / 1.0, y: y / 1.0})
      canvas
    end)
  end

  defp program_graph_points do
    FakeDataSource.put(:metric_range, fn ->
      now = System.system_time(:millisecond)
      {:ok, for(i <- 29..0//-1, do: {now - i * 60_000, 50.0 + rem(i, 7) * 5.0})}
    end)
  end

  # --- Flows ---

  test "1. mount renders seeded elements and pushed graph polylines" do
    program_graph_points()

    canvas = Canvas.new(snap_to_grid: false)
    {canvas, _} = Canvas.add_element(canvas, %{type: :rect, x: 150.0, y: 150.0})
    {canvas, _} = Canvas.add_element(canvas, %{type: :server, x: 420.0, y: 150.0, label: "web-1"})

    {canvas, _} =
      Canvas.add_element(canvas, %{
        type: :graph,
        x: 700.0,
        y: 150.0,
        width: 220.0,
        height: 120.0,
        label: "cpu",
        meta: %{"host" => "web-1", "metric_name" => "cpu_usage"}
      })

    seed(11, canvas)
    run_flow("render", path: "/canvas/11")
  end

  test "2. place a rect via toolbar and a host via typeahead" do
    FakeDataSource.put(:list_hosts, ["alpha-host", "beta-host"])
    seed(12, Canvas.new(snap_to_grid: false))
    run_flow("place_rect_and_host", path: "/canvas/12")
  end

  test "3. dragging an element persists its position across reload" do
    seed(13, rect_canvas([{200, 200}]))
    run_flow("drag_persist", path: "/canvas/13")
  end

  test "4. resizing via the SE handle grows the element" do
    seed(14, rect_canvas([{250, 220}]))
    run_flow("resize_se", path: "/canvas/14")
  end

  test "5. marquee select, Backspace delete, Ctrl+Z restore" do
    seed(15, rect_canvas([{150, 150}, {430, 320}]))
    run_flow("marquee_delete_undo", path: "/canvas/15")
  end

  test "6. wheel pans, ctrl+wheel zooms at cursor, keyboard +/- zooms" do
    seed(16, Canvas.new(snap_to_grid: false))
    run_flow("wheel_zoom_pan", path: "/canvas/16")
  end

  test "7. Space+drag / middle-mouse pan; legend overlay stays pinned" do
    seed(17, Canvas.new(snap_to_grid: false))
    run_flow("pan_legend_fixed", path: "/canvas/17")
  end

  test "8. timeline scrub enters historical mode; Go Live returns" do
    seed(18, Canvas.new(snap_to_grid: false))
    run_flow("timeline_scrub_golive", path: "/canvas/18")
  end

  test "9. undo/redo via buttons and keyboard" do
    seed(19, Canvas.new(snap_to_grid: false))
    run_flow("undo_redo", path: "/canvas/19")
  end

  test "10. read-only viewer cannot move elements; toast on denied edit" do
    previous = Application.get_env(:timeless_canvas, :auth)
    Application.put_env(:timeless_canvas, :auth, TimelessCanvas.Test.DenyEditAuth)
    on_exit(fn -> Application.put_env(:timeless_canvas, :auth, previous) end)

    seed(20, rect_canvas([{260, 240}]))
    run_flow("read_only", path: "/canvas/20")
  end

  test "11. clicking a stream row opens the popover for that entry" do
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
    now = System.system_time(:millisecond)

    FakeStreamBackend.set_query_result(
      {:ok,
       %{
         entries: [
           %{
             timestamp: now,
             level: :error,
             message: "checkout failed for order 421",
             metadata: %{"host" => "web-1"}
           },
           %{
             timestamp: now - 1_000,
             level: :info,
             message: "payment accepted",
             metadata: %{"host" => "web-1"}
           }
         ]
       }}
    )

    canvas = Canvas.new(snap_to_grid: false)

    {canvas, el} =
      Canvas.add_element(canvas, %{
        type: :log_stream,
        x: 200.0,
        y: 160.0,
        width: 320.0,
        height: 180.0,
        label: "web logs",
        meta: %{"host" => "web-1"}
      })

    on_exit(fn -> StreamManager.unregister_stream(el.id) end)

    seed(21, canvas)
    run_flow("stream_entry_click", path: "/canvas/21")
  end

  test "12. Escape cascade: share overlay -> typeahead -> place mode -> selection" do
    FakeDataSource.put(:list_hosts, ["alpha-host"])
    seed(22, rect_canvas([{300, 260}]))
    run_flow("escape_cascade", path: "/canvas/22")
  end

  test "13. focus scoping: Backspace on the timeline track must not delete" do
    seed(23, rect_canvas([{300, 260}]))
    run_flow("focus_scoping_backspace", path: "/canvas/23")
  end

  test "visual regression: reference canvas screenshot" do
    canvas = Canvas.new(snap_to_grid: false)
    {canvas, r} = Canvas.add_element(canvas, %{type: :rect, x: 140.0, y: 140.0, label: "Zone A"})

    {canvas, s} =
      Canvas.add_element(canvas, %{type: :server, x: 430.0, y: 150.0, label: "web-1"})

    {canvas, _} =
      Canvas.add_element(canvas, %{type: :database, x: 720.0, y: 150.0, label: "pg-main"})

    {canvas, _} =
      Canvas.add_element(canvas, %{
        type: :text,
        x: 160.0,
        y: 420.0,
        label: "Reference canvas — do not change"
      })

    {canvas, _conn} = Canvas.add_connection(canvas, r.id, s.id)

    seed(24, canvas)
    run_flow("visual_reference", path: "/canvas/24")
  end
end
