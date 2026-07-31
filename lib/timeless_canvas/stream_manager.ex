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
  """

  use GenServer

  @max_buffer 50
  @flush_cap 50
  @default_batch_ms 250

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

  # --- Server callbacks ---

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{subscriptions: %{}, batch_ms: opts[:batch_ms]}}
  end

  @impl true
  def handle_call({:register, type, canvas_id, element_id, opts}, _from, state) do
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
        sub -> sub.buffer
      end

    {:reply, buffer, state}
  end

  @impl true
  def handle_info({:stream_log_entry, element_id, entry}, state) do
    # Same shape (and therefore the same content-derived id) as the
    # historical maps built in DataQueries.query_stream_data/3.
    entry_map =
      TimelessCanvas.DataQueries.put_entry_id(%{
        timestamp: entry.timestamp,
        level: entry.level,
        message: entry.message,
        metadata: entry.metadata
      })

    {:noreply, buffer_entry(state, element_id, entry_map)}
  end

  def handle_info({:stream_trace_span, element_id, span}, state) do
    span_map =
      TimelessCanvas.DataQueries.put_entry_id(%{
        timestamp: Map.get(span, :start_time) || Map.get(span, :timestamp),
        trace_id: span.trace_id,
        span_id: span.span_id,
        name: span.name,
        kind: span.kind,
        duration_ns: span.duration_ns,
        status: span.status,
        status_message: span.status_message,
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

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  defp stream_backend(type) do
    backends = TimelessCanvas.stream_backends()
    Keyword.get(backends, type) || backends[type]
  end

  defp respawn_subscription(state, backend, type, canvas_id, element_id, opts) do
    state = do_unregister(state, element_id)
    manager = self()

    task_pid =
      spawn_link(fn ->
        subscribe_and_forward(backend, type, element_id, opts, manager)
      end)

    sub = %{
      type: type,
      canvas_id: canvas_id,
      task_pid: task_pid,
      buffer: [],
      opts: opts,
      pending: [],
      flush_timer: nil
    }

    put_in(state, [:subscriptions, element_id], sub)
  end

  defp do_unregister(state, element_id) do
    case Map.pop(state.subscriptions, element_id) do
      {nil, _subs} ->
        state

      {sub, subs} ->
        cancel_flush_timer(sub)
        if Process.alive?(sub.task_pid), do: Process.exit(sub.task_pid, :shutdown)
        %{state | subscriptions: subs}
    end
  end

  defp cancel_flush_timer(%{flush_timer: nil}), do: :ok
  defp cancel_flush_timer(%{flush_timer: timer}), do: Process.cancel_timer(timer)

  defp subscribe_and_forward(backend, type, element_id, opts, manager) do
    backend.subscribe(opts)
    receive_loop(type, element_id, manager)
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
    cond do
      is_map(span.attributes) && Map.has_key?(span.attributes, "service.name") ->
        span.attributes["service.name"]

      is_map(span.resource) && Map.has_key?(span.resource, "service.name") ->
        span.resource["service.name"]

      true ->
        nil
    end
  end
end
