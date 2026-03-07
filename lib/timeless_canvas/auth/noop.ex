defmodule TimelessCanvas.Auth.Noop do
  @moduledoc """
  Allow-all authorization. Every user can do everything.
  Use this as a default when the host app handles auth externally.
  """

  @behaviour TimelessCanvas.Auth

  @impl true
  def admin?(_user), do: false

  @impl true
  def authorize(_user, _canvas_record, _action), do: :ok
end
