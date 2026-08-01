defmodule TimelessCanvas.Presence do
  @moduledoc """
  Phoenix.Presence tracker for canvas editors.

  Each connected `CanvasLive` tracks itself on `topic/1` for its canvas
  (key: user id, meta: display name), so every viewer of a canvas can
  render who else is currently looking at it.

  Started by `TimelessCanvas.Supervisor`; the pubsub server comes from
  `TimelessCanvas.pubsub()` at supervisor start (the same configured
  pubsub every other part of the library uses).
  """

  use Phoenix.Presence, otp_app: :timeless_canvas

  @doc "Per-canvas presence topic."
  def topic(canvas_id), do: "timeless_canvas:canvas:#{canvas_id}:presence"

  @doc """
  Users currently present on the canvas: `[%{id: id, name: name}]`,
  sorted by name. One entry per user, however many tabs they have open.
  """
  def users(canvas_id) do
    canvas_id
    |> topic()
    |> list()
    |> Enum.map(fn {key, %{metas: [meta | _]}} ->
      %{id: key, name: meta[:name] || "user ##{key}"}
    end)
    |> Enum.sort_by(& &1.name)
  end
end
