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
  def admin?(%{role: role}) when role in ["admin", :admin], do: true
  def admin?(_), do: false

  @impl true
  def authorize(%{id: user_id} = user, %{id: canvas_id, user_id: owner_id}, action) do
    cond do
      admin?(user) -> :ok
      owner_id == user_id -> :ok
      true -> check_access(user_id, canvas_id, action)
    end
  end

  def authorize(_user, _canvas_record, _action), do: {:error, :unauthorized}

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
  rescue
    _ -> nil
  end

  defp check_role(:owner, _action), do: :ok
  defp check_role(:editor, :view), do: :ok
  defp check_role(:editor, :edit), do: :ok
  defp check_role(:editor, _), do: {:error, :unauthorized}
  defp check_role(:viewer, :view), do: :ok
  defp check_role(:viewer, _), do: {:error, :unauthorized}
  defp check_role(_, _), do: {:error, :unauthorized}
end
