defmodule TimelessCanvas.Clipboard do
  @moduledoc """
  Per-user element clipboard shared across canvas LiveViews.

  Copy/cut used to stash the copied element templates in a socket
  assign, but `push_navigate` into a sub-canvas remounts the LiveView
  and the assign died with it — cutting elements from a parent canvas
  and pasting them into a child (the canvas-splitting workflow) pasted
  nothing. Storing the templates here, keyed by user id, survives the
  remount.

  Keying by user (not by LiveView) also means two tabs of the same user
  share one clipboard — intentional, matching OS clipboard semantics.

  Entries carry their insertion timestamp; `get/1` enforces a ~30 minute
  TTL lazily on read and deletes expired entries, so no sweeper process
  is needed.

  Storage is a public named ETS table owned by this (otherwise idle)
  GenServer. As in `TimelessCanvas.DataSource.Manager`, init and every
  reader guard with `:ets.whereis/1` so a restart of the owner finds no
  table gone missing mid-call and a read before startup returns empty
  instead of raising.
  """

  use GenServer

  @table :timeless_canvas_clipboard
  @ttl_ms 30 * 60 * 1000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @doc """
  Store `templates` (a list of `TimelessCanvas.Canvas.Element` structs)
  as `user_id`'s clipboard contents, replacing any previous contents.
  """
  def put(user_id, templates) when is_list(templates) do
    if :ets.whereis(@table) != :undefined do
      :ets.insert(@table, {user_id, templates, now_ms()})
    end

    :ok
  end

  @doc """
  The user's clipboard templates, or `[]` when absent or older than the
  TTL (an expired entry is deleted on read).
  """
  def get(user_id) do
    with tid when tid != :undefined <- :ets.whereis(@table),
         [{^user_id, templates, put_at}] <- :ets.lookup(tid, user_id) do
      if now_ms() - put_at <= @ttl_ms do
        templates
      else
        :ets.delete(tid, user_id)
        []
      end
    else
      _ -> []
    end
  end

  @doc "Drop the user's clipboard contents."
  def clear(user_id) do
    case :ets.whereis(@table) do
      :undefined -> :ok
      tid -> :ets.delete(tid, user_id)
    end

    :ok
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  # --- Server callbacks ---

  @impl true
  def init(_opts) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    end

    {:ok, %{}}
  end
end
