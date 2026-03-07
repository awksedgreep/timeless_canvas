defmodule TimelessCanvas.Canvas.History do
  @moduledoc """
  Undo/redo history using full Canvas snapshots.
  Stores past states, the current (present) state, and future states for redo.
  """

  alias TimelessCanvas.Canvas

  defstruct past: [], present: nil, future: [], max_size: 50

  @type t :: %__MODULE__{
          past: [Canvas.t()],
          present: Canvas.t(),
          future: [Canvas.t()],
          max_size: pos_integer()
        }

  @doc """
  Create a new history with the given canvas as the present state.
  """
  def new(%Canvas{} = canvas, opts \\ []) do
    max_size = Keyword.get(opts, :max_size, 50)
    %__MODULE__{present: canvas, max_size: max_size}
  end

  @doc """
  Push a new canvas state. Clears the future (no redo after new action).
  Trims past to max_size.
  """
  def push(%__MODULE__{} = history, %Canvas{} = canvas) do
    past =
      [history.present | history.past]
      |> Enum.take(history.max_size)

    %{history | past: past, present: canvas, future: []}
  end

  @doc """
  Undo: move present to future, pop past to present.
  Returns unchanged history if nothing to undo.
  """
  def undo(%__MODULE__{past: []} = history), do: history

  def undo(%__MODULE__{past: [prev | rest]} = history) do
    %{history | past: rest, present: prev, future: [history.present | history.future]}
  end

  @doc """
  Redo: move present to past, pop future to present.
  Returns unchanged history if nothing to redo.
  """
  def redo(%__MODULE__{future: []} = history), do: history

  def redo(%__MODULE__{future: [next | rest]} = history) do
    %{history | past: [history.present | history.past], present: next, future: rest}
  end

  @doc "Can we undo?"
  def can_undo?(%__MODULE__{past: past}), do: past != []

  @doc "Can we redo?"
  def can_redo?(%__MODULE__{future: future}), do: future != []
end
