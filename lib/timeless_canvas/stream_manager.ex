defmodule TimelessCanvas.StreamManager do
  @moduledoc """
  GenServer that manages live log and trace stream subscriptions.

  Each canvas element of type :log_stream or :trace_stream registers here.
  A dedicated Task per element subscribes via the configured stream backend,
  then forwards messages to this GenServer for buffering and PubSub broadcast.
  """

  use GenServer

  @max_buffer 50

  def topic, do: "timeless_canvas:streams"

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  def register_log_stream(element_id, opts \\ [], server \\ __MODULE__) do
    GenServer.call(server, {:register, :log, element_id, opts})
  end

  def register_trace_stream(element_id, opts \\ [], server \\ __MODULE__) do
    GenServer.call(server, {:register, :trace, element_id, opts})
  end

  def unregister_stream(element_id, server \\ __MODULE__) do
    GenServer.call(server, {:unregister, element_id})
  end

  def get_buffer(element_id, server \\ __MODULE__) do
    GenServer.call(server, {:get_buffer, element_id})
  end

  # --- Server callbacks ---

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{subscriptions: %{}}}
  end

  @impl true
  def handle_call({:register, type, element_id, opts}, _from, state) do
    case stream_backend(type) do
      nil ->
        {:reply, :ok, state}

      backend ->
        state = do_unregister(state, element_id)

        manager = self()

        task_pid =
          spawn_link(fn ->
            subscribe_and_forward(backend, type, element_id, opts, manager)
          end)

        sub = %{type: type, task_pid: task_pid, buffer: [], opts: opts}
        state = put_in(state, [:subscriptions, element_id], sub)
        {:reply, :ok, state}
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
    entry_map = %{
      timestamp: entry.timestamp,
      level: entry.level,
      message: entry.message,
      metadata: entry.metadata
    }

    state = buffer_and_broadcast(state, element_id, :stream_entry, entry_map)
    {:noreply, state}
  end

  def handle_info({:stream_trace_span, element_id, span}, state) do
    span_map = %{
      timestamp: Map.get(span, :start_time) || Map.get(span, :timestamp),
      trace_id: span.trace_id,
      span_id: span.span_id,
      name: span.name,
      kind: span.kind,
      duration_ns: span.duration_ns,
      status: span.status,
      status_message: span.status_message,
      service: get_service(span)
    }

    state = buffer_and_broadcast(state, element_id, :stream_span, span_map)
    {:noreply, state}
  end

  def handle_info({:EXIT, pid, _reason}, state) do
    state =
      case Enum.find(state.subscriptions, fn {_id, sub} -> sub.task_pid == pid end) do
        {element_id, _sub} ->
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

  defp do_unregister(state, element_id) do
    case Map.pop(state.subscriptions, element_id) do
      {nil, _subs} ->
        state

      {sub, subs} ->
        if Process.alive?(sub.task_pid), do: Process.exit(sub.task_pid, :shutdown)
        %{state | subscriptions: subs}
    end
  end

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

  defp buffer_and_broadcast(state, element_id, msg_type, entry_map) do
    case get_in(state, [:subscriptions, element_id]) do
      nil ->
        state

      sub ->
        buffer = Enum.take([entry_map | sub.buffer], @max_buffer)
        sub = %{sub | buffer: buffer}
        state = put_in(state, [:subscriptions, element_id], sub)

        Phoenix.PubSub.broadcast(
          TimelessCanvas.pubsub(),
          topic(),
          {msg_type, element_id, entry_map}
        )

        state
    end
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
