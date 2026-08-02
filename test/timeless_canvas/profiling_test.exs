defmodule TimelessCanvas.ProfilingTest do
  # async: false — the profiling flag is cached in :persistent_term
  # (global) and these tests flip it.
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias TimelessCanvas.Canvas
  alias TimelessCanvas.Components.CanvasComponents
  alias TimelessCanvas.Profiling

  defp with_profiling(enabled?) do
    Application.put_env(:timeless_canvas, :profiling, enabled?)
    Profiling.refresh()

    on_exit(fn ->
      Application.delete_env(:timeless_canvas, :profiling)
      Profiling.refresh()
    end)
  end

  defp render_element do
    {_canvas, el} =
      Canvas.add_element(Canvas.new(), %{type: :server, label: "srv", x: 100.0, y: 100.0})

    render_component(&CanvasComponents.canvas_element/1, element: el)
  end

  defp clear_render_stats do
    Process.delete(:canvas_element_calls)
    Process.delete(:canvas_element_time_us)
  end

  test "profiling is disabled by default" do
    Application.delete_env(:timeless_canvas, :profiling)
    refute Profiling.refresh()
    refute Profiling.enabled?()
  end

  test "refresh/0 picks up an enabled app env" do
    with_profiling(true)
    assert Profiling.enabled?()
  end

  test "timed/1 calls the fun directly (zero elapsed) when disabled" do
    with_profiling(false)
    assert {0, :ran} = Profiling.timed(fn -> :ran end)
  end

  test "timed/1 measures via :timer.tc when enabled" do
    with_profiling(true)

    assert {elapsed_us, :ran} =
             Profiling.timed(fn ->
               Process.sleep(2)
               :ran
             end)

    assert elapsed_us >= 1_000
  end

  test "with profiling on, rendering an element bumps the render counters" do
    with_profiling(true)
    clear_render_stats()

    assert render_element() =~ "canvas-element"
    assert Process.get(:canvas_element_calls) == 1
    assert is_integer(Process.get(:canvas_element_time_us))
  end

  test "with profiling off, rendering leaves no process-dictionary counters" do
    with_profiling(false)
    clear_render_stats()

    assert render_element() =~ "canvas-element"
    assert Process.get(:canvas_element_calls) == nil
    assert Process.get(:canvas_element_time_us) == nil
  end
end
