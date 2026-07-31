defmodule TimelessCanvas.Test.FakeDataSource do
  @moduledoc """
  Programmable implementation of `TimelessCanvas.DataSource` for tests.

  Every callback returns a benign default (like `Stub`, except `time_range/1`
  which returns a real one-hour range so timeline code works). Tests can
  override any callback's return value with function-name-keyed canned
  responses:

      FakeDataSource.put(:list_hosts, ["host-a", "host-b"])
      FakeDataSource.put(:metric_range, {:ok, [{ts, 1.0}]})

  A canned value that is a 0-arity function is invoked on every call, so
  tests can inject per-call behaviour (latency, raises, changing values):

      FakeDataSource.put(:time_range, fn -> raise "backend down" end)

  Canned values are stored in a public ETS table and cleared by `reset/0`
  (done automatically by `TimelessCanvas.ConnCase`).

  Discovery callbacks (`list_hosts/2`, `list_label_values/3`,
  `list_series_for_host/3`) apply `:filter` / `:limit` opts to the canned
  list, so tests can program a full list and assert bounding.

  The batch callbacks `statuses/2` and `statuses_at/3` default to mapping
  each element to the canned `:status` / `:status_at` value; program
  `:statuses` / `:statuses_at` with a full `%{id => status}` map to
  override.
  """

  @behaviour TimelessCanvas.DataSource

  alias TimelessCanvas.DataSource

  @table :timeless_canvas_fake_data_source

  # --- Test API ---

  @doc "Ensure the backing ETS table exists. Called once from test_helper."
  def ensure_table! do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table])
    end

    :ok
  end

  @doc "Register a canned response for the given callback name."
  def put(fun_name, value) when is_atom(fun_name) do
    ensure_table!()
    :ets.insert(@table, {fun_name, value})
    :ok
  end

  @doc "Clear all canned responses. Call between tests."
  def reset do
    ensure_table!()
    :ets.delete_all_objects(@table)
    :ok
  end

  defp get(fun_name, default) do
    ensure_table!()

    case :ets.lookup(@table, fun_name) do
      [{^fun_name, value}] when is_function(value, 0) -> value.()
      [{^fun_name, value}] -> value
      [] -> default
    end
  end

  # --- TimelessCanvas.DataSource callbacks ---

  @impl true
  def init(_config), do: get(:init, {:ok, %{}})

  @impl true
  def status(_state, _element), do: get(:status, :unknown)

  @impl true
  def metric(_state, _element, _metric), do: get(:metric, :no_data)

  @impl true
  def subscribe(state, _element), do: {:ok, state}

  @impl true
  def unsubscribe(state, _element), do: {:ok, state}

  @impl true
  def handle_message(_state, _message), do: get(:handle_message, :ignore)

  @impl true
  def metric_at(_state, _element, _metric, _time), do: get(:metric_at, :no_data)

  @impl true
  def metric_range(_state, _element, _metric, _from, _to), do: get(:metric_range, {:ok, []})

  @impl true
  def status_at(_state, _element, _time), do: get(:status_at, :unknown)

  @impl true
  def statuses(_state, elements) do
    case get(:statuses, :default) do
      :default -> Map.new(elements, &{&1.id, get(:status, :unknown)})
      canned -> canned
    end
  end

  @impl true
  def statuses_at(_state, elements, _time) do
    case get(:statuses_at, :default) do
      :default -> Map.new(elements, &{&1.id, get(:status_at, :unknown)})
      canned -> canned
    end
  end

  @impl true
  def time_range(_state) do
    get(:time_range, :default) |> default_time_range()
  end

  defp default_time_range(:default) do
    now = DateTime.utc_now()
    {DateTime.add(now, -3600, :second), now}
  end

  defp default_time_range(canned), do: canned

  @impl true
  def event_density(_state, _from, _to, buckets) do
    get(:event_density, List.duplicate(0, buckets))
  end

  @impl true
  def list_series_for_host(_state, _host, opts) do
    get(:list_series_for_host, [])
    |> DataSource.apply_query_opts(opts, fn {name, _labels} -> name end)
  end

  @impl true
  def list_hosts(_state, opts) do
    get(:list_hosts, []) |> DataSource.apply_query_opts(opts)
  end

  @impl true
  def list_label_values(_state, _label_key, opts) do
    get(:list_label_values, []) |> DataSource.apply_query_opts(opts)
  end

  @impl true
  def metric_metadata(_state, _metric_name), do: get(:metric_metadata, {:ok, nil})

  @impl true
  def text_metric(_state, _element, _metric), do: get(:text_metric, :no_data)

  @impl true
  def text_metric_at(_state, _element, _metric, _time), do: get(:text_metric_at, :no_data)
end
