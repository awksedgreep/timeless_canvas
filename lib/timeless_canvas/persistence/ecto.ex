defmodule TimelessCanvas.Persistence.Ecto do
  @moduledoc """
  Ecto-backed persistence for canvas records.
  Uses the repo configured via `config :timeless_canvas, :repo`.
  """

  @behaviour TimelessCanvas.Persistence

  import Ecto.Query

  alias TimelessCanvas.Schemas.{CanvasRecord, CanvasAccess}

  defp repo, do: TimelessCanvas.repo()

  @impl true
  def get_canvas(id) do
    case repo().get(CanvasRecord, id) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  @impl true
  def save_canvas(user_id, name, data) do
    case repo().get_by(CanvasRecord, user_id: user_id, name: name) do
      nil ->
        %CanvasRecord{}
        |> CanvasRecord.changeset(%{user_id: user_id, name: name, data: data})
        |> repo().insert()

      existing ->
        existing
        |> CanvasRecord.changeset(%{data: data})
        |> repo().update()
    end
  end

  @impl true
  def create_canvas(user_id, name) do
    %CanvasRecord{}
    |> CanvasRecord.changeset(%{user_id: user_id, name: name, data: %{}})
    |> repo().insert()
  end

  @impl true
  def create_child_canvas(parent_id, name) do
    case repo().get(CanvasRecord, parent_id) do
      nil ->
        {:error, :parent_not_found}

      parent ->
        %CanvasRecord{}
        |> CanvasRecord.changeset(%{
          user_id: parent.user_id,
          name: name,
          data: %{},
          parent_id: parent.id
        })
        |> repo().insert()
    end
  end

  @impl true
  def update_canvas_data(canvas_id, data) do
    case repo().get(CanvasRecord, canvas_id) do
      nil ->
        {:error, :not_found}

      record ->
        record
        |> CanvasRecord.changeset(%{data: data})
        |> repo().update()
    end
  end

  @impl true
  def rename_canvas(id, user_id, new_name) do
    case repo().get_by(CanvasRecord, id: id, user_id: user_id) do
      nil ->
        {:error, :not_found}

      record ->
        record
        |> CanvasRecord.changeset(%{name: new_name})
        |> repo().update()
    end
  end

  @impl true
  def delete_canvas(id, user_id) do
    case repo().get_by(CanvasRecord, id: id, user_id: user_id) do
      nil -> {:error, :not_found}
      record -> repo().delete(record)
    end
  end

  @impl true
  def list_accessible_canvases(user) do
    owned =
      CanvasRecord
      |> where([c], c.user_id == ^user.id)

    shared_ids =
      CanvasAccess
      |> where([a], a.user_id == ^user.id)
      |> select([a], a.canvas_id)

    shared =
      CanvasRecord
      |> where([c], c.id in subquery(shared_ids))

    union_query = union(owned, ^shared)

    from(c in subquery(union_query), order_by: [asc: c.name])
    |> repo().all()
  end

  @impl true
  def breadcrumb_chain(canvas_id) do
    case repo().get(CanvasRecord, canvas_id) do
      nil -> []
      record -> build_chain(record, [{record.id, record.name}])
    end
  end

  defp build_chain(%{parent_id: nil}, acc), do: acc

  defp build_chain(%{parent_id: parent_id}, acc) do
    case repo().get(CanvasRecord, parent_id) do
      nil -> acc
      parent -> build_chain(parent, [{parent.id, parent.name} | acc])
    end
  end

  @impl true
  def grant_access(canvas_id, user_id, role) do
    %CanvasAccess{}
    |> CanvasAccess.changeset(%{canvas_id: canvas_id, user_id: user_id, role: role})
    |> repo().insert(
      on_conflict: [set: [role: role]],
      conflict_target: [:canvas_id, :user_id]
    )
  end

  @impl true
  def revoke_access(canvas_id, user_id) do
    case repo().get_by(CanvasAccess, canvas_id: canvas_id, user_id: user_id) do
      nil -> {:error, :not_found}
      access -> repo().delete(access)
    end
  end

  @impl true
  def list_access(canvas_id) do
    CanvasAccess
    |> where([a], a.canvas_id == ^canvas_id)
    |> preload(:user)
    |> repo().all()
  end

  @impl true
  def lookup_user_by_email(email) do
    case TimelessCanvas.user_schema() do
      nil -> nil
      schema -> repo().get_by(schema, email: email)
    end
  end
end
