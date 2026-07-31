defmodule TimelessCanvas.Test.DenyEditAuth do
  @moduledoc """
  Auth module that allows viewing but denies editing for everyone.

  Swap it in per test via the `:auth` app env (restore with `on_exit`) to
  exercise the read-only (`can_edit: false`) paths that `Auth.Noop` can
  never reach.
  """

  @behaviour TimelessCanvas.Auth

  @impl true
  def admin?(_user), do: false

  @impl true
  def authorize(_user, _canvas_record, :view), do: :ok
  def authorize(_user, _canvas_record, _action), do: {:error, :unauthorized}
end
