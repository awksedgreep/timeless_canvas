defmodule TimelessCanvas.CanvasPoller do
  @moduledoc """
  Shared per-canvas live-data poller.

  One poller process runs per open canvas (registered in
  `TimelessCanvas.CanvasRegistry`, started under
  `TimelessCanvas.PollerSupervisor`). Each tick it queries graph and
  text-series data once for the whole canvas via
  `TimelessCanvas.DataQueries`, diffs the results against the last
  broadcast, and publishes only changed entries as

      {:canvas_data, canvas_id, %{graph_data: %{...}, text_data: %{...}}}

  on `data_topic(canvas_id)`. N viewers of the same canvas therefore cost
  one query fan-out per tick instead of N (previously every CanvasLive ran
  its own `:graph_refresh` timer).

  Subscribers (`subscribe/3`) are monitored; when the last one goes away
  the poller lingers briefly (default 30s, so a page reload reuses the
  warm process) and then stops. The restart strategy is `:temporary`:
  subscriber monitors and diff state cannot survive a crash anyway, every
  LiveView mount calls `ensure_started/2` + `subscribe/3`, and an
  auto-restarted poller would sit subscriber-less until the linger stop —
  so restarting adds churn without adding data flow.
  """

  use GenServer, restart: :temporary

  alias TimelessCanvas.DataQueries

  @registry TimelessCanvas.CanvasRegistry
  @supervisor TimelessCanvas.PollerSupervisor
  @default_poll_interval 10_000
  @default_linger 30_000
  @default_span 3600

  # --- Client API ---

  @doc "PubSub topic carrying `{:canvas_data, canvas_id, diffs}` messages."
  def data_topic(canvas_id), do: "timeless_canvas:canvas:#{canvas_id}:data"

  @doc """
  Start (or reuse) the poller for `canvas_id`.

  Options: `:poll_interval` and `:linger` (milliseconds, mostly for
  tests); ignored when the poller is already running.
  """
  def ensure_started(canvas_id, opts \\ []) do
    spec = {__MODULE__, Keyword.put(opts, :canvas_id, canvas_id)}

    case DynamicSupervisor.start_child(@supervisor, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  @doc """
  Register the caller as a subscriber and replace the polled element set
  (all viewers of a canvas share the same elements, so last write wins).
  Starts the poller if needed. `opts` may carry `:span` (seconds of graph
  history per tick) plus `ensure_started/2` options.
  """
  def subscribe(canvas_id, resolved_elements, opts \\ []) do
    with {:ok, pid} <- ensure_started(canvas_id, opts) do
      GenServer.call(pid, {:subscribe, self(), resolved_elements, opts[:span]})
    end
  catch
    # The poller stopping between ensure_started and the call must never
    # take the LiveView down; the next update_elements/subscribe recovers.
    :exit, _reason -> :error
  end

  @doc """
  Replace the polled element set (and optionally the span) after canvas
  membership or meta changes. No-op when no poller is running.
  """
  def update_elements(canvas_id, resolved_elements, opts \\ []) do
    case whereis(canvas_id) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:update_elements, resolved_elements, opts[:span]})
    end
  end

  @doc "Pid of the poller for `canvas_id`, or nil."
  def whereis(canvas_id) do
    case Registry.lookup(@registry, canvas_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  def start_link(opts) do
    canvas_id = Keyword.fetch!(opts, :canvas_id)
    GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {@registry, canvas_id}})
  end

  # --- Server callbacks ---

  @impl true
  def init(opts) do
    ds_config = TimelessCanvas.data_source_config()

    poll_interval =
      opts[:poll_interval] || Keyword.get(ds_config, :poll_interval, @default_poll_interval)

    state = %{
      canvas_id: Keyword.fetch!(opts, :canvas_id),
      poll_interval: poll_interval,
      linger: opts[:linger] || @default_linger,
      span: opts[:span] || @default_span,
      elements: %{},
      subscribers: %{},
      last_graph: %{},
      last_text_values: %{}
    }

    schedule_poll(poll_interval)
    # Stop eventually if nobody ever subscribes (e.g. after a crash).
    schedule_idle_check(state.linger)
    {:ok, state}
  end

  @impl true
  def handle_call({:subscribe, pid, resolved_elements, span}, _from, state) do
    subscribers =
      if Map.has_key?(state.subscribers, pid) do
        state.subscribers
      else
        Map.put(state.subscribers, pid, Process.monitor(pid))
      end

    state =
      %{state | subscribers: subscribers, span: span || state.span}
      |> put_elements(resolved_elements)

    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:update_elements, resolved_elements, span}, state) do
    {:noreply, %{state | span: span || state.span} |> put_elements(resolved_elements)}
  end

  @impl true
  def handle_info(:poll, state) do
    state =
      if map_size(state.subscribers) > 0 and pollable?(state.elements) do
        poll_and_broadcast(state)
      else
        state
      end

    schedule_poll(state.poll_interval)
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    subscribers = Map.delete(state.subscribers, pid)

    if map_size(subscribers) == 0 do
      schedule_idle_check(state.linger)
    end

    {:noreply, %{state | subscribers: subscribers}}
  end

  def handle_info(:idle_check, state) do
    if map_size(state.subscribers) == 0 do
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  # --- Private ---

  defp schedule_poll(interval), do: Process.send_after(self(), :poll, interval)

  defp schedule_idle_check(linger), do: Process.send_after(self(), :idle_check, linger)

  defp put_elements(state, resolved_elements) do
    ids = Map.keys(resolved_elements)

    %{
      state
      | elements: resolved_elements,
        last_graph: Map.take(state.last_graph, ids),
        last_text_values: Map.take(state.last_text_values, ids)
    }
  end

  defp pollable?(elements) do
    Enum.any?(elements, fn {_id, el} -> el.type in [:graph, :text_series] end)
  end

  defp poll_and_broadcast(state) do
    now = DateTime.utc_now()
    graph_data = DataQueries.query_graph_data(state.canvas_id, state.elements, now, state.span)
    text_data = DataQueries.query_text_data(state.canvas_id, state.elements, now)

    changed_graph =
      for {id, points} <- graph_data,
          Map.get(state.last_graph, id) != points,
          into: %{},
          do: {id, points}

    # Text results are stamped with the query time, so diff on the value
    # alone — otherwise every tick would look changed. Entries may also be
    # `:error` (backend failure), which must broadcast on transition too so
    # viewers can show — and later clear — the error state.
    changed_text =
      for {id, stamped} <- text_data,
          Map.get(state.last_text_values, id, :no_value) != text_diff_value(stamped),
          into: %{},
          do: {id, stamped}

    if map_size(changed_graph) > 0 or map_size(changed_text) > 0 do
      Phoenix.PubSub.broadcast(
        TimelessCanvas.pubsub(),
        data_topic(state.canvas_id),
        {:canvas_data, state.canvas_id, %{graph_data: changed_graph, text_data: changed_text}}
      )
    end

    changed_text_values =
      Map.new(changed_text, fn {id, stamped} -> {id, text_diff_value(stamped)} end)

    %{
      state
      | last_graph: Map.merge(state.last_graph, changed_graph),
        last_text_values: Map.merge(state.last_text_values, changed_text_values)
    }
  end

  defp text_diff_value({_ts, value}), do: value
  defp text_diff_value(:error), do: :error
end
