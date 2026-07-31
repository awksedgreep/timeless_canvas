defmodule TimelessCanvas.Test.FakePersistence do
  @moduledoc """
  In-memory implementation of `TimelessCanvas.Persistence` backed by an Agent.

  Tests seed records with `seed_canvas/1` and reset state between tests with
  `reset/0` (done automatically by `TimelessCanvas.ConnCase`).
  """

  @behaviour TimelessCanvas.Persistence

  use Agent

  @initial_state %{canvases: %{}, access: %{}, users: %{}, next_id: 1, update_error: nil}

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> @initial_state end, name: __MODULE__)
  end

  @doc "Reset all stored state. Call between tests."
  def reset do
    Agent.update(__MODULE__, fn _ -> @initial_state end)
  end

  @doc """
  Insert a canvas record with the given attrs and return it.

  Defaults: `name`, `user_id: 1`, `data: %{}`, `parent_id: nil`.
  """
  def seed_canvas(attrs \\ %{}) do
    Agent.get_and_update(__MODULE__, fn state ->
      id = state.next_id
      now = DateTime.utc_now()

      record =
        %{
          id: id,
          name: "Canvas #{id}",
          user_id: 1,
          data: %{},
          parent_id: nil,
          inserted_at: now,
          updated_at: now
        }
        |> Map.merge(Map.new(attrs))

      state = %{
        state
        | canvases: Map.put(state.canvases, record.id, record),
          next_id: max(state.next_id, record.id) + 1
      }

      {record, state}
    end)
  end

  @doc """
  Force every subsequent `update_canvas_data/2` call to return `error`
  (an `{:error, reason}` tuple). Pass `nil` to restore normal behaviour;
  `reset/0` also clears it.
  """
  def fail_update_canvas_data(error \\ {:error, :forced_failure}) do
    Agent.update(__MODULE__, &Map.put(&1, :update_error, error))
  end

  @doc "Register a user so `lookup_user_by_username/1` can find it."
  def seed_user(user) do
    Agent.update(__MODULE__, fn state ->
      %{state | users: Map.put(state.users, user.username, user)}
    end)
  end

  # --- TimelessCanvas.Persistence callbacks ---

  @impl true
  def get_canvas(id) do
    case Agent.get(__MODULE__, &Map.get(&1.canvases, id)) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  @impl true
  def save_canvas(user_id, name, data) do
    existing =
      Agent.get(__MODULE__, fn state ->
        Enum.find_value(state.canvases, fn {_id, c} ->
          if c.user_id == user_id and c.name == name, do: c
        end)
      end)

    case existing do
      nil -> {:ok, seed_canvas(%{user_id: user_id, name: name, data: data})}
      record -> update_canvas_data(record.id, data)
    end
  end

  @impl true
  def create_canvas(user_id, name) do
    {:ok, seed_canvas(%{user_id: user_id, name: name, data: %{}})}
  end

  @impl true
  def create_child_canvas(parent_id, name) do
    case get_canvas(parent_id) do
      {:error, :not_found} ->
        {:error, :parent_not_found}

      {:ok, parent} ->
        {:ok,
         seed_canvas(%{user_id: parent.user_id, name: name, data: %{}, parent_id: parent.id})}
    end
  end

  @impl true
  def update_canvas_data(canvas_id, data) do
    case Agent.get(__MODULE__, & &1.update_error) do
      nil -> update_record(canvas_id, fn record -> %{record | data: data} end)
      error -> error
    end
  end

  @impl true
  def rename_canvas(id, user_id, new_name) do
    case get_canvas(id) do
      {:ok, %{user_id: ^user_id}} ->
        update_record(id, fn record -> %{record | name: new_name} end)

      _ ->
        {:error, :not_found}
    end
  end

  @impl true
  def delete_canvas(id, user_id) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.get(state.canvases, id) do
        %{user_id: ^user_id} = record ->
          {{:ok, record}, %{state | canvases: Map.delete(state.canvases, id)}}

        _ ->
          {{:error, :not_found}, state}
      end
    end)
  end

  @impl true
  def list_accessible_canvases(user) do
    Agent.get(__MODULE__, fn state ->
      shared_ids =
        state.access
        |> Map.values()
        |> Enum.filter(&(&1.user_id == user.id))
        |> Enum.map(& &1.canvas_id)

      state.canvases
      |> Map.values()
      |> Enum.filter(fn c -> c.user_id == user.id or c.id in shared_ids end)
      |> Enum.sort_by(& &1.name)
    end)
  end

  @impl true
  def breadcrumb_chain(canvas_id) do
    case get_canvas(canvas_id) do
      {:error, :not_found} -> []
      {:ok, record} -> build_chain(record, [{record.id, record.name}])
    end
  end

  defp build_chain(%{parent_id: nil}, acc), do: acc

  defp build_chain(%{parent_id: parent_id}, acc) do
    case get_canvas(parent_id) do
      {:error, :not_found} -> acc
      {:ok, parent} -> build_chain(parent, [{parent.id, parent.name} | acc])
    end
  end

  @impl true
  def grant_access(canvas_id, user_id, role) do
    Agent.get_and_update(__MODULE__, fn state ->
      # Use the seeded user when one matches so rendered access rows carry
      # a real username; otherwise synthesize one.
      user =
        Enum.find_value(state.users, fn {_username, user} ->
          if user.id == user_id, do: user
        end) || %{id: user_id, username: "user-#{user_id}"}

      entry = %{canvas_id: canvas_id, user_id: user_id, role: role, user: user}
      {{:ok, entry}, %{state | access: Map.put(state.access, {canvas_id, user_id}, entry)}}
    end)
  end

  @impl true
  def revoke_access(canvas_id, user_id) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.pop(state.access, {canvas_id, user_id}) do
        {nil, _} -> {{:error, :not_found}, state}
        {entry, access} -> {{:ok, entry}, %{state | access: access}}
      end
    end)
  end

  @impl true
  def list_access(canvas_id) do
    Agent.get(__MODULE__, fn state ->
      state.access
      |> Map.values()
      |> Enum.filter(&(&1.canvas_id == canvas_id))
    end)
  end

  @impl true
  def lookup_user_by_username(username) do
    Agent.get(__MODULE__, &Map.get(&1.users, username))
  end

  defp update_record(id, fun) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.get(state.canvases, id) do
        nil ->
          {{:error, :not_found}, state}

        record ->
          record = record |> fun.() |> Map.put(:updated_at, DateTime.utc_now())
          {{:ok, record}, %{state | canvases: Map.put(state.canvases, id, record)}}
      end
    end)
  end
end
