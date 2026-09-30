defmodule TimelessCanvas.DataSource.Random do
  @moduledoc """
  Demo data source that randomly assigns statuses and generates fake metric values.
  Useful for development and testing status indicators without a real backend.

  Time travel returns random statuses seeded by element ID + time, so scrubbing
  to the same timestamp produces consistent results.
  """

  @behaviour TimelessCanvas.DataSource

  alias TimelessCanvas.DataSource

  @statuses [:ok, :warning, :error, :unknown]

  @demo_hosts for role <- ~w(web db cache worker), i <- 1..4, do: "#{role}-0#{i}"

  @demo_metrics ~w(cpu_usage memory_usage disk_usage network_rx_bytes network_tx_bytes load_avg)

  @demo_label_values %{
    "ifname" => ~w(eth0 eth1 lo bond0),
    "env" => ~w(prod staging dev)
  }

  @impl true
  def init(_config), do: {:ok, %{}}

  @impl true
  def status(_state, _element) do
    Enum.random(@statuses)
  end

  @impl true
  def metric(_state, _element, _metric) do
    {:ok, :rand.uniform() * 100}
  end

  @impl true
  def subscribe(state, _element), do: {:ok, state}

  @impl true
  def unsubscribe(state, _element), do: {:ok, state}

  @impl true
  def handle_message(_state, _message), do: :ignore

  @impl true
  def metric_range(_state, element, metric, %DateTime{} = from, %DateTime{} = to) do
    from_ms = DateTime.to_unix(from, :millisecond)
    to_ms = DateTime.to_unix(to, :millisecond)

    points =
      Stream.iterate(from_ms, &(&1 + 2000))
      |> Enum.take_while(&(&1 <= to_ms))
      |> Enum.map(fn ms ->
        bucket = div(ms, 2000)
        seed = :erlang.phash2({element.id, metric})
        phase = seed / 65535.0 * 2 * :math.pi()
        value = 50.0 + 30.0 * :math.sin(bucket / 15.0 + phase)
        {ms, Float.round(value, 1)}
      end)

    {:ok, points}
  end

  # The demo series are already one line per element, so combining them
  # changes nothing; exporting this is what offers the option in the UI.
  @impl true
  def metric_range(state, element, metric, from, to, _opts),
    do: metric_range(state, element, metric, from, to)

  @impl true
  def top_series(_state, element, metric, %DateTime{} = time, opts) do
    bucket = div(DateTime.to_unix(time, :second), 10)

    label_key =
      case opts[:group_by] do
        [key | _] -> key
        _ -> "host"
      end

    names = Map.get(@demo_label_values, label_key, @demo_hosts)

    rows =
      names
      |> Enum.map(fn name ->
        seed = :erlang.phash2({element.id, metric, name})
        phase = seed / 65535.0 * 2 * :math.pi()
        value = 50.0 + 45.0 * :math.sin(bucket / 15.0 + phase)
        %{labels: %{label_key => name}, value: Float.round(value, 1)}
      end)
      |> Enum.sort_by(& &1.value, opts[:order] || :desc)
      |> Enum.take(opts[:limit] || 10)

    {:ok, rows}
  end

  @impl true
  def metric_at(_state, element, metric, %DateTime{} = time) do
    bucket = div(DateTime.to_unix(time, :millisecond), 2000)
    seed = :erlang.phash2({element.id, metric})
    phase = seed / 65535.0 * 2 * :math.pi()
    value = 50.0 + 30.0 * :math.sin(bucket / 15.0 + phase)
    {:ok, Float.round(value, 1)}
  end

  @impl true
  def status_at(_state, element, %DateTime{} = time) do
    bucket = div(DateTime.to_unix(time, :second), 10)
    hash = :erlang.phash2({element.id, bucket}, length(@statuses))
    Enum.at(@statuses, hash)
  end

  @impl true
  def time_range(_state) do
    now = DateTime.utc_now()
    one_hour_ago = DateTime.add(now, -3600, :second)
    {one_hour_ago, now}
  end

  @impl true
  def list_hosts(_state, opts) do
    DataSource.apply_query_opts(@demo_hosts, opts)
  end

  @impl true
  def list_label_values(_state, label_key, opts) do
    @demo_label_values
    |> Map.get(label_key, [])
    |> DataSource.apply_query_opts(opts)
  end

  @impl true
  def list_series_for_host(_state, host, opts) do
    @demo_metrics
    |> Enum.map(&{&1, %{"host" => host}})
    |> DataSource.filter_series(opts)
  end

  @impl true
  def event_density(_state, %DateTime{} = from, %DateTime{} = to, buckets) do
    from_ms = DateTime.to_unix(from, :millisecond)
    to_ms = DateTime.to_unix(to, :millisecond)
    bucket_width = max(div(to_ms - from_ms, buckets), 1)

    Enum.map(0..(buckets - 1), fn i ->
      bucket_start = from_ms + i * bucket_width
      seed = :erlang.phash2({:density, div(bucket_start, 10_000)})
      rem(seed, 20) + 1
    end)
  end
end
