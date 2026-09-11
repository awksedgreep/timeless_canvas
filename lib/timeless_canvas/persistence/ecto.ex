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
    %CanvasRecord{}
    |> CanvasRecord.changeset(%{user_id: user_id, name: name, data: data})
    |> repo().insert(
      on_conflict: {:replace, [:data, :updated_at]},
      conflict_target: [:user_id, :name],
      returning: true
    )
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
      nil ->
        {:error, :not_found}

      record ->
        repo().transaction(fn ->
          from(a in CanvasAccess, where: a.canvas_id == ^record.id) |> repo().delete_all()

          from(c in CanvasRecord, where: c.parent_id == ^record.id)
          |> repo().update_all(set: [parent_id: nil])

          case repo().delete(record) do
            {:ok, deleted} -> deleted
            {:error, reason} -> repo().rollback(reason)
          end
        end)
        |> unwrap_transaction()
    end
  end

  @impl true
  def list_accessible_canvases(user) do
    list_accessible_canvases(user, [])
  end

  @doc "A bounded page of accessible canvases ordered by name and id."
  def list_accessible_canvases(user, opts) when is_list(opts) do
    limit = page_integer(opts[:limit], 500, 1, 500)
    offset = page_integer(opts[:offset], 0, 0, 1_000_000_000)

    from(c in CanvasRecord,
      left_join: a in CanvasAccess,
      on: a.canvas_id == c.id and a.user_id == ^user.id,
      where: c.user_id == ^user.id or not is_nil(a.id),
      distinct: true,
      order_by: [asc: c.name, asc: c.id],
      select: struct(c, [:id, :name, :user_id, :parent_id, :inserted_at, :updated_at]),
      limit: ^limit,
      offset: ^offset
    )
    |> repo().all()
  end

  @impl true
  def breadcrumb_chain(canvas_id) do
    case repo().get(CanvasRecord, canvas_id) do
      nil -> []
      record -> build_chain(record, [{record.id, record.name}], MapSet.new([record.id]), 1)
    end
  end

  defp build_chain(%{parent_id: nil}, acc, _visited, _depth), do: acc
  defp build_chain(_record, acc, _visited, depth) when depth >= 50, do: acc

  defp build_chain(%{parent_id: parent_id}, acc, visited, depth) do
    if MapSet.member?(visited, parent_id) do
      acc
    else
      case repo().get(CanvasRecord, parent_id) do
        nil ->
          acc

        parent ->
          build_chain(
            parent,
            [{parent.id, parent.name} | acc],
            MapSet.put(visited, parent.id),
            depth + 1
          )
      end
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
    accesses = CanvasAccess |> where([a], a.canvas_id == ^canvas_id) |> repo().all()

    users =
      case TimelessCanvas.user_schema() do
        nil ->
          %{}

        schema ->
          ids = Enum.map(accesses, & &1.user_id)
          schema |> where([u], u.id in ^ids) |> repo().all() |> Map.new(&{&1.id, &1})
      end

    Enum.map(accesses, &%{&1 | user: Map.get(users, &1.user_id)})
  end

  @impl true
  def lookup_user_by_username(username) do
    case TimelessCanvas.user_schema() do
      nil -> nil
      schema -> repo().get_by(schema, username: username)
    end
  end

  defp unwrap_transaction({:ok, value}), do: {:ok, value}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

  defp page_integer(value, default, minimum, maximum) do
    value = if is_integer(value), do: value, else: default
    value |> max(minimum) |> min(maximum)
  end
end
