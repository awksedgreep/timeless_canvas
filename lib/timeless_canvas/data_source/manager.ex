defmodule TimelessCanvas.DataSource.Manager do
  @moduledoc """
  GenServer that manages the active data source module and polls element statuses.

  - Holds the active data source module + its state
  - Polls `status/2` for each tracked element on a configurable interval
  - Broadcasts status changes via `Phoenix.PubSub` on configurable topic
  - Delegates time-travel queries to the data source
  """

  use GenServer
  require Logger

  @default_module TimelessCanvas.DataSource.Stub
  @default_poll_interval 10_000
  @debug_report_interval 30_000

  def status_topic, do: "timeless_canvas:status"
  def metric_topic, do: "timeless_canvas:metrics"

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  def register_elements(elements, server \\ __MODULE__) when is_list(elements) do
    GenServer.call(server, {:register_elements, elements})
  end

  def unregister_element(element_id, server \\ __MODULE__) do
    GenServer.cast(server, {:unregister_element, element_id})
  end

  def statuses_at(time, server \\ __MODULE__) do
    GenServer.call(server, {:statuses_at, time})
  end

  def metric_at(element_id, metric_name, time, server \\ __MODULE__) do
    GenServer.call(server, {:metric_at, element_id, metric_name, time})
  end

  def metric_range(element_id, metric_name, from, to, server \\ __MODULE__) do
    GenServer.call(server, {:metric_range, element_id, metric_name, from, to}, 30_000)
  end

  def time_range(server \\ __MODULE__) do
    GenServer.call(server, :time_range)
  end

  def data_density(from, to, buckets \\ 80, server \\ __MODULE__) do
    GenServer.call(server, {:data_density, from, to, buckets}, 10_000)
  end

  def list_series_for_host(host, server \\ __MODULE__) do
    GenServer.call(server, {:list_series_for_host, host}, 10_000)
  end

  def list_hosts(server \\ __MODULE__) do
    GenServer.call(server, :list_hosts, 10_000)
  end

  def metric_metadata(metric_name, server \\ __MODULE__) do
    GenServer.call(server, {:metric_metadata, metric_name}, 10_000)
  end

  def list_label_values(label_key, server \\ __MODULE__) do
    GenServer.call(server, {:list_label_values, label_key}, 10_000)
  end

  def text_metric_at(element_id, metric_name, time, server \\ __MODULE__) do
    GenServer.call(server, {:text_metric_at, element_id, metric_name, time})
  end

  # --- Server callbacks ---

  @impl true
  def init(opts) do
    ds_config = TimelessCanvas.data_source_config()
    module = Keyword.get(ds_config, :module, opts[:module] || @default_module)
    config = Keyword.get(ds_config, :config, opts[:config] || %{})

    poll_interval =
      Keyword.get(ds_config, :poll_interval, opts[:poll_interval] || @default_poll_interval)

    case module.init(config) do
      {:ok, ds_state} ->
        state = %{
          module: module,
          ds_state: ds_state,
          elements: %{},
          poll_interval: poll_interval,
          last_statuses: %{},
          debug: %{
            register_calls: 0,
            registered_elements: 0,
            polls: 0,
            poll_time_us: 0,
            statuses_broadcast: 0,
            metrics_broadcast: 0,
            text_metrics_broadcast: 0
          }
        }

        schedule_poll(poll_interval)
        schedule_debug_report()
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:register_elements, elements}, _from, state) do
    {ds_state, element_map} =
      Enum.reduce(elements, {state.ds_state, state.elements}, fn element, {ds, elmap} ->
        {:ok, ds} = state.module.subscribe(ds, element)
        {ds, Map.put(elmap, element.id, element)}
      end)

    debug =
      state.debug
      |> Map.update!(:register_calls, &(&1 + 1))
      |> Map.put(:registered_elements, map_size(element_map))

    {:reply, :ok, %{state | ds_state: ds_state, elements: element_map, debug: debug}}
  end

  @impl true
  def handle_call({:statuses_at, time}, _from, state) do
    statuses =
      Enum.reduce(state.elements, %{}, fn {id, element}, acc ->
        Map.put(acc, id, state.module.status_at(state.ds_state, element, time))
      end)

    {:reply, statuses, state}
  end

  def handle_call({:metric_at, element_id, metric_name, time}, _from, state) do
    result =
      case Map.get(state.elements, element_id) do
        nil -> :no_data
        element -> state.module.metric_at(state.ds_state, element, metric_name, time)
      end

    {:reply, result, state}
  end

  def handle_call({:metric_range, element_id, metric_name, from, to}, _from, state) do
    result =
      case Map.get(state.elements, element_id) do
        nil -> {:ok, []}
        element -> state.module.metric_range(state.ds_state, element, metric_name, from, to)
      end

    {:reply, result, state}
  end

  def handle_call(:time_range, _from, state) do
    {:reply, state.module.time_range(state.ds_state), state}
  end

  def handle_call({:data_density, from, to, buckets}, _from, state) do
    result =
      if function_exported?(state.module, :event_density, 4) do
        state.module.event_density(state.ds_state, from, to, buckets)
      else
        []
      end

    {:reply, result, state}
  end

  def handle_call({:list_series_for_host, host}, _from, state) do
    result =
      if function_exported?(state.module, :list_series_for_host, 2) do
        state.module.list_series_for_host(state.ds_state, host)
      else
        []
      end

    {:reply, result, state}
  end

  def handle_call(:list_hosts, _from, state) do
    result =
      if function_exported?(state.module, :list_hosts, 1) do
        state.module.list_hosts(state.ds_state)
      else
        []
      end

    {:reply, result, state}
  end

  def handle_call({:list_label_values, label_key}, _from, state) do
    result =
      if function_exported?(state.module, :list_label_values, 2) do
        state.module.list_label_values(state.ds_state, label_key)
      else
        []
      end

    {:reply, result, state}
  end

  def handle_call({:metric_metadata, metric_name}, _from, state) do
    result =
      if function_exported?(state.module, :metric_metadata, 2) do
        state.module.metric_metadata(state.ds_state, metric_name)
      else
        {:ok, nil}
      end

    {:reply, result, state}
  end

  def handle_call({:text_metric_at, element_id, metric_name, time}, _from, state) do
    result =
      case Map.get(state.elements, element_id) do
        nil ->
          :no_data

        element ->
          if function_exported?(state.module, :text_metric_at, 4) do
            state.module.text_metric_at(state.ds_state, element, metric_name, time)
          else
            :no_data
          end
      end

    {:reply, result, state}
  end

  @impl true
  def handle_cast({:unregister_element, element_id}, state) do
    case Map.pop(state.elements, element_id) do
      {nil, _elements} ->
        {:noreply, state}

      {element, elements} ->
        {:ok, ds_state} = state.module.unsubscribe(state.ds_state, element)
        last_statuses = Map.delete(state.last_statuses, element_id)

        {:noreply,
         %{state | ds_state: ds_state, elements: elements, last_statuses: last_statuses}}
    end
  end

  @impl true
  def handle_info(:poll, state) do
    {poll_us, state} =
      :timer.tc(fn ->
        state
        |> update_in([:debug, :polls], &(&1 + 1))
        |> poll_all()
      end)

    state = update_in(state, [:debug, :poll_time_us], &(&1 + poll_us))

    schedule_poll(state.poll_interval)
    {:noreply, state}
  end

  def handle_info(:debug_report, state) do
    Logger.info(
      "[canvas-prof] manager polls=#{state.debug.polls} register_calls=#{state.debug.register_calls} " <>
        "registered_elements=#{state.debug.registered_elements} status_broadcasts=#{state.debug.statuses_broadcast} " <>
        "metric_broadcasts=#{state.debug.metrics_broadcast} text_metric_broadcasts=#{state.debug.text_metrics_broadcast} " <>
        "poll_time_ms=#{Float.round(state.debug.poll_time_us / 1000, 1)}"
    )

    schedule_debug_report()

    debug = %{
      state.debug
      | polls: 0,
        register_calls: 0,
        poll_time_us: 0,
        statuses_broadcast: 0,
        metrics_broadcast: 0,
        text_metrics_broadcast: 0
    }

    {:noreply, %{state | debug: debug}}
  end

  def handle_info(message, state) do
    case state.module.handle_message(state.ds_state, message) do
      {:status, element_id, status} ->
        state = maybe_broadcast_status(state, element_id, status)
        {:noreply, state}

      {:metric, _element_id, _metric_name, _value} ->
        {:noreply, state}

      :ignore ->
        {:noreply, state}
    end
  end

  # --- Private ---

  defp schedule_poll(interval) do
    Process.send_after(self(), :poll, interval)
  end

  defp schedule_debug_report do
    Process.send_after(self(), :debug_report, @debug_report_interval)
  end

  defp poll_all(state) do
    pubsub = TimelessCanvas.pubsub()

    Enum.reduce(state.elements, state, fn {element_id, element}, acc ->
      acc = maybe_broadcast_status(acc, element_id, state.module.status(acc.ds_state, element))

      acc =
        if element.type == :graph do
          poll_metric(acc, element_id, element, pubsub)
        else
          acc
        end

      if element.type == :text_series do
        poll_text_metric(acc, element_id, element, pubsub)
      else
        acc
      end
    end)
  end

  defp poll_metric(state, element_id, element, pubsub) do
    metric_name = Map.get(element.meta, "metric_name", "default")

    case state.module.metric(state.ds_state, element, metric_name) do
      {:ok, value} ->
        timestamp = System.system_time(:millisecond)

        Phoenix.PubSub.broadcast(
          pubsub,
          metric_topic(),
          {:element_metric, element_id, metric_name, value, timestamp}
        )

        put_in(state.debug.metrics_broadcast, state.debug.metrics_broadcast + 1)

      :no_data ->
        state
    end
  end

  defp poll_text_metric(state, element_id, element, pubsub) do
    metric_name = Map.get(element.meta, "metric_name", "default")

    if function_exported?(state.module, :text_metric, 3) do
      case state.module.text_metric(state.ds_state, element, metric_name) do
        {:ok, value} ->
          timestamp = System.system_time(:millisecond)

          Phoenix.PubSub.broadcast(
            pubsub,
            metric_topic(),
            {:element_text_metric, element_id, metric_name, value, timestamp}
          )

          put_in(state.debug.text_metrics_broadcast, state.debug.text_metrics_broadcast + 1)

        :no_data ->
          state
      end
    else
      state
    end
  end

  defp maybe_broadcast_status(state, element_id, status) do
    if Map.get(state.last_statuses, element_id) != status do
      Phoenix.PubSub.broadcast(
        TimelessCanvas.pubsub(),
        status_topic(),
        {:element_status, element_id, status}
      )

      state
      |> Map.update!(:last_statuses, &Map.put(&1, element_id, status))
      |> update_in([:debug, :statuses_broadcast], &(&1 + 1))
    else
      state
    end
  end
end
