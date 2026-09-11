defmodule TimelessCanvas.StreamManager do
  @moduledoc """
  GenServer that manages live log and trace stream subscriptions.

  Each canvas element of type :log_stream or :trace_stream registers here
  under the canvas it belongs to. A dedicated Task per element subscribes
  via the configured stream backend, then forwards messages to this
  GenServer for buffering and PubSub broadcast.

  Registration is idempotent: re-registering an element with the same
  backend opts while its subscription task is alive is a no-op (the
  existing subscription is kept). Only a change in opts — or a dead task —
  tears the subscription down and re-subscribes.

  Broadcasts are batched per element and go out on the per-canvas
  `stream_topic/1`: entries accumulate for `:stream_batch_ms`
  (app env, default 250ms) and are then published as one

      {:stream_entries, element_id, [entry, ...]}   # log streams
      {:stream_spans, element_id, [span, ...]}      # trace streams

  message per element per window, newest entry first. A window is flushed
  early when it reaches 50 pending entries (backpressure cap).

  Registering processes are monitored per canvas: when the last
  registrant of a canvas exits (e.g. its LiveView goes away), that
  canvas's stream subscriptions are torn down, so subscriptions for
  closed canvases no longer accumulate. While a second viewer of the
  same canvas is alive, its subscriptions are kept.
  """

  use GenServer
  require Logger

  @max_buffer 50
  @flush_cap 50
  @default_batch_ms 250
  @default_retry_ms 1_000

  @doc "Per-canvas PubSub topic carrying batched stream broadcasts."
  def stream_topic(canvas_id), do: "timeless_canvas:canvas:#{canvas_id}:streams"

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  def register_log_stream(canvas_id, element_id, opts \\ [], server \\ __MODULE__) do
    GenServer.call(server, {:register, :log, canvas_id, element_id, opts})
  end

  def register_trace_stream(canvas_id, element_id, opts \\ [], server \\ __MODULE__) do
    GenServer.call(server, {:register, :trace, canvas_id, element_id, opts})
  end

  def unregister_stream(element_id, server \\ __MODULE__) do
    GenServer.call(server, {:unregister, element_id})
  end

  def get_buffer(element_id, server \\ __MODULE__) do
    GenServer.call(server, {:get_buffer, element_id})
  end

  @doc false
  def reset(server \\ __MODULE__), do: GenServer.call(server, :reset)

  # --- Server callbacks ---

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       subscriptions: %{},
       registrants: %{},
       batch_ms: opts[:batch_ms],
       retry_ms: opts[:retry_ms] || @default_retry_ms
     }}
  end

  @impl true
  def handle_call({:register, type, canvas_id, element_id, opts}, {caller, _tag}, state) do
    state = monitor_registrant(state, canvas_id, caller)

    case stream_backend(type) do
      nil ->
        {:reply, :ok, state}

      backend ->
        case state.subscriptions[element_id] do
          %{type: ^type, opts: ^opts, task_pid: pid} = sub when is_pid(pid) ->
            if Process.alive?(pid) do
              # Identical live registration: keep the subscription, just
              # track the (possibly different) canvas for broadcasts.
              {:reply, :ok,
               put_in(state, [:subscriptions, element_id], %{sub | canvas_id: canvas_id})}
            else
              {:reply, :ok,
               respawn_subscription(state, backend, type, canvas_id, element_id, opts)}
            end

          _ ->
            {:reply, :ok, respawn_subscription(state, backend, type, canvas_id, element_id, opts)}
        end
    end
  end

  def handle_call({:unregister, element_id}, _from, state) do
    state = do_unregister(state, element_id)
    {:reply, :ok, state}
  end

  def handle_call({:get_buffer, element_id}, _from, state) do
    buffer =
      case get_in(state, [:subscriptions, element_id]) do
        nil -> []
        %{error: true} -> :error
        sub -> sub.buffer
      end

    {:reply, buffer, state}
  end

  def handle_call(:reset, _from, state) do
    state = Enum.reduce(Map.keys(state.subscriptions), state, &do_unregister(&2, &1))

    Enum.each(state.registrants, fn {_canvas_id, registrants} ->
      Enum.each(registrants, fn {_pid, ref} -> Process.demonitor(ref, [:flush]) end)
    end)

    {:reply, :ok, %{state | subscriptions: %{}, registrants: %{}}}
  end

  @impl true
  def handle_info({:stream_log_entry, element_id, entry}, state) do
    # Same shape (and therefore the same content-derived id) as the
    # historical maps built in DataQueries.query_stream_data/3.
    entry_map =
      TimelessCanvas.DataQueries.put_entry_id(%{
        timestamp: value(entry, :timestamp),
        level: value(entry, :level),
        message: value(entry, :message, ""),
        metadata: value(entry, :metadata, %{})
      })

    {:noreply, buffer_entry(state, element_id, entry_map)}
  end

  def handle_info({:stream_trace_span, element_id, span}, state) do
    span_map =
      TimelessCanvas.DataQueries.put_entry_id(%{
        timestamp: value(span, :start_time) || value(span, :timestamp),
        trace_id: value(span, :trace_id),
        span_id: value(span, :span_id),
        name: value(span, :name, ""),
        kind: value(span, :kind),
        duration_ns: value(span, :duration_ns),
        status: value(span, :status),
        status_message: value(span, :status_message),
        service: get_service(span)
      })

    {:noreply, buffer_entry(state, element_id, span_map)}
  end

  def handle_info({:flush, element_id}, state) do
    {:noreply, flush_pending(state, element_id)}
  end

  def handle_info({:EXIT, pid, _reason}, state) do
    state =
      case Enum.find(state.subscriptions, fn {_id, sub} -> sub.task_pid == pid end) do
        {element_id, sub} ->
          cancel_flush_timer(sub)
          %{state | subscriptions: Map.delete(state.subscriptions, element_id)}

        nil ->
          state
      end

    {:noreply, state}
  end

  def handle_info({:subscription_ready, element_id, pid}, state) do
    case get_in(state, [:subscriptions, element_id]) do
      %{task_pid: ^pid} = sub ->
        {:noreply,
         put_in(state, [:subscriptions, element_id], %{
           sub
           | error: false,
             retry_attempt: 0,
             retry_timer: nil
         })}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:subscription_failed, element_id, pid, reason}, state) do
    case get_in(state, [:subscriptions, element_id]) do
      %{task_pid: ^pid} = sub ->
        Logger.warning(
          "TimelessCanvas stream subscription #{element_id} failed: #{inspect(reason)}"
        )

        attempt = sub.retry_attempt + 1
        delay = min(state.retry_ms * trunc(:math.pow(2, attempt - 1)), 30_000)
        timer = Process.send_after(self(), {:retry_subscription, element_id}, delay)

        {:noreply,
         put_in(state, [:subscriptions, element_id], %{
           sub
           | task_pid: nil,
             error: true,
             retry_attempt: attempt,
             retry_timer: timer
         })}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:retry_subscription, element_id}, state) do
    case get_in(state, [:subscriptions, element_id]) do
      nil -> {:noreply, state}
      sub -> {:noreply, restart_subscription(state, element_id, sub)}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    {:noreply, drop_registrant(state, pid, ref)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  defp monitor_registrant(state, canvas_id, pid) do
    canvas_pids = Map.get(state.registrants, canvas_id, %{})

    if Map.has_key?(canvas_pids, pid) do
      state
    else
      canvas_pids = Map.put(canvas_pids, pid, Process.monitor(pid))
      %{state | registrants: Map.put(state.registrants, canvas_id, canvas_pids)}
    end
  end

  # A registrant exited: canvases whose registrant set empties lose all
  # of their stream subscriptions (mirrors DataSource.Manager).
  defp drop_registrant(state, pid, ref) do
    {registrants, emptied} =
      Enum.reduce(state.registrants, {%{}, []}, fn {canvas_id, pids}, {acc, emptied} ->
        case Map.pop(pids, pid) do
          {^ref, rest} when map_size(rest) == 0 -> {acc, [canvas_id | emptied]}
          {^ref, rest} -> {Map.put(acc, canvas_id, rest), emptied}
          {_other, _rest} -> {Map.put(acc, canvas_id, pids), emptied}
        end
      end)

    state = %{state | registrants: registrants}

    Enum.reduce(emptied, state, fn canvas_id, acc ->
      acc.subscriptions
      |> Enum.filter(fn {_element_id, sub} -> sub.canvas_id == canvas_id end)
      |> Enum.reduce(acc, fn {element_id, _sub}, acc2 -> do_unregister(acc2, element_id) end)
    end)
  end

  defp stream_backend(type) do
    backends = TimelessCanvas.stream_backends()
    Keyword.get(backends, type) || backends[type]
  end

  defp respawn_subscription(state, backend, type, canvas_id, element_id, opts) do
    state = do_unregister(state, element_id)

    sub = %{
      type: type,
      canvas_id: canvas_id,
      task_pid: nil,
      buffer: [],
      opts: opts,
      pending: [],
      flush_timer: nil,
      retry_timer: nil,
      retry_attempt: 0,
      error: false
    }

    state
    |> put_in([:subscriptions, element_id], sub)
    |> restart_subscription(element_id, sub, backend)
  end

  defp restart_subscription(state, element_id, sub) do
    case stream_backend(sub.type) do
      nil -> do_unregister(state, element_id)
      backend -> restart_subscription(state, element_id, sub, backend)
    end
  end

  defp restart_subscription(state, element_id, sub, backend) do
    manager = self()

    if sub.retry_timer, do: Process.cancel_timer(sub.retry_timer)

    task_pid =
      spawn_link(fn ->
        subscribe_and_forward(backend, sub.type, element_id, sub.opts, manager)
      end)

    put_in(state, [:subscriptions, element_id], %{sub | task_pid: task_pid, retry_timer: nil})
  end

  defp do_unregister(state, element_id) do
    case Map.pop(state.subscriptions, element_id) do
      {nil, _subs} ->
        state

      {sub, subs} ->
        cancel_flush_timer(sub)
        if sub.retry_timer, do: Process.cancel_timer(sub.retry_timer)

        if is_pid(sub.task_pid) and Process.alive?(sub.task_pid),
          do: Process.exit(sub.task_pid, :shutdown)

        %{state | subscriptions: subs}
    end
  end

  defp cancel_flush_timer(%{flush_timer: nil}), do: :ok
  defp cancel_flush_timer(%{flush_timer: timer}), do: Process.cancel_timer(timer)

  defp subscribe_and_forward(backend, type, element_id, opts, manager) do
    case backend.subscribe(opts) do
      :ok ->
        send(manager, {:subscription_ready, element_id, self()})
        receive_loop(type, element_id, manager)

      {:ok, _subscription} ->
        send(manager, {:subscription_ready, element_id, self()})
        receive_loop(type, element_id, manager)

      {:error, reason} ->
        send(manager, {:subscription_failed, element_id, self(), reason})

      other ->
        send(manager, {:subscription_failed, element_id, self(), {:unexpected_return, other}})
    end
  rescue
    error -> send(manager, {:subscription_failed, element_id, self(), error})
  catch
    kind, reason -> send(manager, {:subscription_failed, element_id, self(), {kind, reason}})
  end

  defp receive_loop(:log, element_id, manager) do
    receive do
      {:timeless_logs, :entry, entry} ->
        send(manager, {:stream_log_entry, element_id, entry})
        receive_loop(:log, element_id, manager)
    end
  end

  defp receive_loop(:trace, element_id, manager) do
    receive do
      {:timeless_traces, :span, span} ->
        send(manager, {:stream_trace_span, element_id, span})
        receive_loop(:trace, element_id, manager)
    end
  end

  defp buffer_entry(state, element_id, entry_map) do
    case get_in(state, [:subscriptions, element_id]) do
      nil ->
        state

      sub ->
        buffer = Enum.take([entry_map | sub.buffer], @max_buffer)
        pending = [entry_map | sub.pending]
        sub = %{sub | buffer: buffer, pending: pending}
        state = put_in(state, [:subscriptions, element_id], sub)

        cond do
          length(pending) >= @flush_cap ->
            flush_pending(state, element_id)

          sub.flush_timer == nil ->
            timer = Process.send_after(self(), {:flush, element_id}, batch_ms(state))
            put_in(state, [:subscriptions, element_id, :flush_timer], timer)

          true ->
            state
        end
    end
  end

  defp flush_pending(state, element_id) do
    case get_in(state, [:subscriptions, element_id]) do
      nil ->
        state

      %{pending: []} = sub ->
        put_in(state, [:subscriptions, element_id], %{sub | flush_timer: nil})

      sub ->
        cancel_flush_timer(sub)
        msg_type = if sub.type == :log, do: :stream_entries, else: :stream_spans

        Phoenix.PubSub.broadcast(
          TimelessCanvas.pubsub(),
          stream_topic(sub.canvas_id),
          {msg_type, element_id, sub.pending}
        )

        put_in(state, [:subscriptions, element_id], %{sub | pending: [], flush_timer: nil})
    end
  end

  defp batch_ms(state) do
    state.batch_ms || Application.get_env(:timeless_canvas, :stream_batch_ms, @default_batch_ms)
  end

  defp get_service(span) do
    attributes = value(span, :attributes, %{})
    resource = value(span, :resource, %{})

    cond do
      is_map(attributes) && Map.has_key?(attributes, "service.name") ->
        attributes["service.name"]

      is_map(resource) && Map.has_key?(resource, "service.name") ->
        resource["service.name"]

      true ->
        nil
    end
  end

  defp value(map, key, default \\ nil) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, nil} -> Map.get(map, Atom.to_string(key), default)
      {:ok, found} -> found
      :error -> Map.get(map, Atom.to_string(key), default)
    end
  end
end
