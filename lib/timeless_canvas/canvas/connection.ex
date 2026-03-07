defmodule TimelessCanvas.Canvas.Connection do
  @moduledoc """
  A connection (edge) between two elements on the canvas.
  """

  defstruct [
    :id,
    :source_id,
    :target_id,
    label: "",
    color: "#8888aa",
    style: :solid,
    meta: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          source_id: String.t(),
          target_id: String.t(),
          label: String.t(),
          color: String.t(),
          style: :solid | :dashed | :dotted,
          meta: map()
        }
end
