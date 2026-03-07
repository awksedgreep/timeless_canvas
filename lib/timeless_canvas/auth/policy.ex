defmodule TimelessCanvas.Auth.Policy do
  @moduledoc """
  Authorization policy for canvas operations.

  Admin users have role "admin" on the user struct.
  Canvas owners have full control. Editors can view and edit.
  Viewers can only view.
  """

  @behaviour TimelessCanvas.Auth

  alias TimelessCanvas.Schemas.CanvasAccess

  import Ecto.Query

  defp repo, do: TimelessCanvas.repo()

  @impl true
  def admin?(%{role: "admin"}), do: true
  def admin?(_), do: false

  @impl true
  def authorize(user, canvas_record, action) do
    cond do
      admin?(user) -> :ok
      canvas_record.user_id == user.id -> :ok
      true -> check_access(user.id, canvas_record.id, action)
    end
  end

  defp check_access(user_id, canvas_id, action) do
    case get_role(user_id, canvas_id) do
      nil -> {:error, :unauthorized}
      role -> check_role(role, action)
    end
  end

  defp get_role(user_id, canvas_id) do
    CanvasAccess
    |> where([a], a.user_id == ^user_id and a.canvas_id == ^canvas_id)
    |> select([a], a.role)
    |> repo().one()
  end

  defp check_role(:owner, _action), do: :ok
  defp check_role(:editor, :view), do: :ok
  defp check_role(:editor, :edit), do: :ok
  defp check_role(:editor, _), do: {:error, :unauthorized}
  defp check_role(:viewer, :view), do: :ok
  defp check_role(:viewer, _), do: {:error, :unauthorized}
end
