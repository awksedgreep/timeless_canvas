defmodule TimelessCanvas.DataSource.Manager do
  @moduledoc """
  GenServer that manages the active data source module and polls element statuses.

  - Holds the active data source module + its state
  - Polls `status/2` for each tracked element on a configurable interval
  - Broadcasts status changes via `Phoenix.PubSub` on the per-canvas
    `status_topic/1` of the canvas each element was registered under

  Read-only queries (`metric_range/5`, `list_hosts/1`, time-travel lookups,
  etc.) execute in the **caller process**: the Manager publishes the data
  source module, its state, and the registered-element map to a public ETS
  table, and the query functions read from that table and call the data
  source directly. Only registration (which mutates data-source state via
  `subscribe/2` / `unsubscribe/2`) and the poll loop go through the
  GenServer, so one slow scan no longer blocks every other client.
  """

  use GenServer
  require Logger

  alias TimelessCanvas.DataSource

  @default_module TimelessCanvas.DataSource.Stub
  @default_poll_interval 10_000
  @debug_report_interval 30_000

  @table :timeless_canvas_data_source

  @doc """
  Per-canvas status topic: `{:element_status, element_id, status}` changes
  for elements registered under `canvas_id` are broadcast here (previously
  one global topic fanned every status change out to every client of every
  canvas).
  """
  def status_topic(canvas_id), do: "timeless_canvas:canvas:#{canvas_id}:status"

  # --- Client API (GenServer-backed: mutates data-source state) ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  def register_elements(canvas_id, elements, server \\ __MODULE__) when is_list(elements) do
    GenServer.call(server, {:register_elements, canvas_id, elements})
  end

  def unregister_element(element_id, server \\ __MODULE__) do
    GenServer.cast(server, {:unregister_element, element_id})
  end

  # --- Client API (caller-side: reads config from ETS, queries directly) ---

  def statuses_at(time) do
    case lookup_source() do
      {:ok, module, ds_state} ->
        elements = lookup_elements()

        if function_exported?(module, :statuses_at, 3) do
          module.statuses_at(ds_state, Map.values(elements), time)
        else
          Enum.reduce(elements, %{}, fn {id, element}, acc ->
            Map.put(acc, id, module.status_at(ds_state, element, time))
          end)
        end

      :error ->
        %{}
    end
  end

  def metric_at(element_id, metric_name, time) do
    with {:ok, module, ds_state} <- lookup_source(),
         {:ok, element} <- lookup_element(element_id) do
      module.metric_at(ds_state, element, metric_name, time)
    else
      _ -> :no_data
    end
  end

  def metric_range(element_id, metric_name, from, to) do
    with {:ok, module, ds_state} <- lookup_source(),
         {:ok, element} <- lookup_element(element_id) do
      module.metric_range(ds_state, element, metric_name, from, to)
    else
      _ -> {:ok, []}
    end
  end

  def time_range do
    case lookup_source() do
      {:ok, module, ds_state} -> module.time_range(ds_state)
      :error -> :empty
    end
  end

  def data_density(from, to, buckets \\ 80) do
    case lookup_source() do
      {:ok, module, ds_state} ->
        if function_exported?(module, :event_density, 4) do
          module.event_density(ds_state, from, to, buckets)
        else
          []
        end

      :error ->
        []
    end
  end

  def list_series_for_host(host, opts \\ []) do
    case lookup_source() do
      {:ok, module, ds_state} ->
        cond do
          function_exported?(module, :list_series_for_host, 3) ->
            module.list_series_for_host(ds_state, host, opts)

          # Back-compat: pre-opts backends export the old arity; apply
          # filter/limit here as a fallback.
          function_exported?(module, :list_series_for_host, 2) ->
            ds_state
            |> module.list_series_for_host(host)
            |> DataSource.apply_query_opts(opts, fn {name, _labels} -> name end)

          true ->
            []
        end

      :error ->
        []
    end
  end

  def list_hosts(opts \\ []) do
    case lookup_source() do
      {:ok, module, ds_state} ->
        cond do
          function_exported?(module, :list_hosts, 2) ->
            module.list_hosts(ds_state, opts)

          function_exported?(module, :list_hosts, 1) ->
            ds_state
            |> module.list_hosts()
            |> DataSource.apply_query_opts(opts)

          true ->
            []
        end

      :error ->
        []
    end
  end

  def list_label_values(label_key, opts \\ []) do
    case lookup_source() do
      {:ok, module, ds_state} ->
        cond do
          function_exported?(module, :list_label_values, 3) ->
            module.list_label_values(ds_state, label_key, opts)

          function_exported?(module, :list_label_values, 2) ->
            ds_state
            |> module.list_label_values(label_key)
            |> DataSource.apply_query_opts(opts)

          true ->
            []
        end

      :error ->
        []
    end
  end

  def metric_metadata(metric_name) do
    case lookup_source() do
      {:ok, module, ds_state} ->
        if function_exported?(module, :metric_metadata, 2) do
          module.metric_metadata(ds_state, metric_name)
        else
          {:ok, nil}
        end

      :error ->
        {:ok, nil}
    end
  end

  def text_metric_at(element_id, metric_name, time) do
    with {:ok, module, ds_state} <- lookup_source(),
         {:ok, element} <- lookup_element(element_id),
         true <- function_exported?(module, :text_metric_at, 4) do
      module.text_metric_at(ds_state, element, metric_name, time)
    else
      _ -> :no_data
    end
  end

  # --- ETS helpers ---

  defp lookup_source do
    with tid when tid != :undefined <- :ets.whereis(@table),
         [{:source, module, ds_state}] <- :ets.lookup(tid, :source) do
      {:ok, module, ds_state}
    else
      _ -> :error
    end
  end

  defp lookup_elements do
    with tid when tid != :undefined <- :ets.whereis(@table),
         [{:elements, elements}] <- :ets.lookup(tid, :elements) do
      elements
    else
      _ -> %{}
    end
  end

  defp lookup_element(element_id) do
    Map.fetch(lookup_elements(), element_id)
  end

  defp publish_source(state) do
    :ets.insert(@table, {:source, state.module, state.ds_state})
    state
  end

  defp publish_elements(state) do
    :ets.insert(@table, {:elements, state.elements})
    state
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
        if :ets.whereis(@table) == :undefined do
          :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
        end

        state = %{
          module: module,
          ds_state: ds_state,
          elements: %{},
          element_canvases: %{},
          poll_interval: poll_interval,
          last_statuses: %{},
          debug: %{
            register_calls: 0,
            registered_elements: 0,
            polls: 0,
            poll_time_us: 0,
            statuses_broadcast: 0
          }
        }

        state
        |> publish_source()
        |> publish_elements()

        schedule_poll(poll_interval)
        schedule_debug_report()
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:register_elements, canvas_id, elements}, _from, state) do
    acc0 = {state.ds_state, state.elements, state.element_canvases}

    {ds_state, element_map, canvas_map} =
      Enum.reduce(elements, acc0, fn element, {ds, elmap, cvmap} ->
        {:ok, ds} = state.module.subscribe(ds, element)
        {ds, Map.put(elmap, element.id, element), Map.put(cvmap, element.id, canvas_id)}
      end)

    debug =
      state.debug
      |> Map.update!(:register_calls, &(&1 + 1))
      |> Map.put(:registered_elements, map_size(element_map))

    state =
      %{
        state
        | ds_state: ds_state,
          elements: element_map,
          element_canvases: canvas_map,
          debug: debug
      }
      |> publish_source()
      |> publish_elements()

    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:unregister_element, element_id}, state) do
    case Map.pop(state.elements, element_id) do
      {nil, _elements} ->
        {:noreply, state}

      {element, elements} ->
        {:ok, ds_state} = state.module.unsubscribe(state.ds_state, element)
        last_statuses = Map.delete(state.last_statuses, element_id)
        element_canvases = Map.delete(state.element_canvases, element_id)

        state =
          %{
            state
            | ds_state: ds_state,
              elements: elements,
              element_canvases: element_canvases,
              last_statuses: last_statuses
          }
          |> publish_source()
          |> publish_elements()

        {:noreply, state}
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
        "poll_time_ms=#{Float.round(state.debug.poll_time_us / 1000, 1)}"
    )

    schedule_debug_report()

    debug = %{
      state.debug
      | polls: 0,
        register_calls: 0,
        poll_time_us: 0,
        statuses_broadcast: 0
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

  # Text-series metric polling moved to TimelessCanvas.CanvasPoller: its
  # per-canvas text_metric_at diff/broadcast covers what the old
  # poll_text_metric -> {:element_text_metric, ...} path did, so the
  # Manager poll loop now only tracks statuses.
  defp poll_all(state) do
    statuses = poll_statuses(state)

    Enum.reduce(state.elements, state, fn {element_id, _element}, acc ->
      case Map.fetch(statuses, element_id) do
        {:ok, status} -> maybe_broadcast_status(acc, element_id, status)
        :error -> acc
      end
    end)
  end

  defp poll_statuses(state) do
    if function_exported?(state.module, :statuses, 2) do
      state.module.statuses(state.ds_state, Map.values(state.elements))
    else
      Enum.reduce(state.elements, %{}, fn {element_id, element}, acc ->
        Map.put(acc, element_id, state.module.status(state.ds_state, element))
      end)
    end
  end

  defp maybe_broadcast_status(state, element_id, status) do
    if Map.get(state.last_statuses, element_id) != status do
      Phoenix.PubSub.broadcast(
        TimelessCanvas.pubsub(),
        status_topic(Map.get(state.element_canvases, element_id)),
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
