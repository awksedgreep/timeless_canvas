defmodule TimelessCanvas.Canvas.HistoryTest do
  use ExUnit.Case, async: true

  alias TimelessCanvas.Canvas
  alias TimelessCanvas.Canvas.History

  # Distinguishable canvas snapshots
  defp canvas(n), do: Canvas.new(next_id: n)

  test "new/2 sets the present state with empty past/future" do
    history = History.new(canvas(1))

    assert history.present == canvas(1)
    assert history.past == []
    assert history.future == []
    assert history.max_size == 50
    refute History.can_undo?(history)
    refute History.can_redo?(history)
  end

  test "push/2 moves present into past" do
    history =
      History.new(canvas(1))
      |> History.push(canvas(2))

    assert history.present == canvas(2)
    assert history.past == [canvas(1)]
    assert History.can_undo?(history)
  end

  test "undo restores the previous state and enables redo" do
    history =
      History.new(canvas(1))
      |> History.push(canvas(2))
      |> History.undo()

    assert history.present == canvas(1)
    assert history.past == []
    assert history.future == [canvas(2)]
    assert History.can_redo?(history)
  end

  test "redo re-applies an undone state" do
    history =
      History.new(canvas(1))
      |> History.push(canvas(2))
      |> History.undo()
      |> History.redo()

    assert history.present == canvas(2)
    assert history.past == [canvas(1)]
    assert history.future == []
  end

  test "undo with empty past is a no-op" do
    history = History.new(canvas(1))
    assert History.undo(history) == history
  end

  test "redo with empty future is a no-op" do
    history = History.new(canvas(1)) |> History.push(canvas(2))
    assert History.redo(history) == history
  end

  test "push clears the redo stack" do
    history =
      History.new(canvas(1))
      |> History.push(canvas(2))
      |> History.undo()
      |> History.push(canvas(3))

    assert history.future == []
    refute History.can_redo?(history)
    assert history.present == canvas(3)
    assert history.past == [canvas(1)]
  end

  test "past is capped at max_size (default 50)" do
    history =
      Enum.reduce(2..60, History.new(canvas(1)), fn n, acc ->
        History.push(acc, canvas(n))
      end)

    assert length(history.past) == 50
    assert history.present == canvas(60)
    # Most recent past entry first
    assert hd(history.past) == canvas(59)
  end

  test "custom max_size is honored" do
    history =
      Enum.reduce(2..10, History.new(canvas(1), max_size: 3), fn n, acc ->
        History.push(acc, canvas(n))
      end)

    assert length(history.past) == 3
    assert history.past == [canvas(9), canvas(8), canvas(7)]
  end

  test "replace_top/2 swaps the present without touching the past" do
    history =
      History.new(canvas(1))
      |> History.push(canvas(2))
      |> History.replace_top(canvas(3))

    assert history.present == canvas(3)
    assert history.past == [canvas(1)]
  end

  test "replace_top/2 then undo skips the replaced snapshot" do
    history =
      History.new(canvas(1))
      |> History.push(canvas(2))
      |> History.replace_top(canvas(3))
      |> History.undo()

    # One undo returns to the pre-burst state, not the coalesced middle one
    assert history.present == canvas(1)
    assert history.future == [canvas(3)]
  end

  test "replace_top/2 clears the redo stack like push/2" do
    history =
      History.new(canvas(1))
      |> History.push(canvas(2))
      |> History.undo()
      |> History.replace_top(canvas(3))

    assert history.present == canvas(3)
    assert history.future == []
    refute History.can_redo?(history)
  end

  test "replace_top/2 on a fresh history only replaces the present" do
    history = History.new(canvas(1)) |> History.replace_top(canvas(2))

    assert history.present == canvas(2)
    assert history.past == []
    refute History.can_undo?(history)
  end

  test "multiple undos walk back through history in order" do
    history =
      History.new(canvas(1))
      |> History.push(canvas(2))
      |> History.push(canvas(3))
      |> History.undo()
      |> History.undo()

    assert history.present == canvas(1)
    assert history.future == [canvas(2), canvas(3)]
  end
end
