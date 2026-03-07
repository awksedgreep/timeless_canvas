defmodule TimelessCanvas.DataSource.Random do
  @moduledoc """
  Demo data source that randomly assigns statuses and generates fake metric values.
  Useful for development and testing status indicators without a real backend.

  Time travel returns random statuses seeded by element ID + time, so scrubbing
  to the same timestamp produces consistent results.
  """

  @behaviour TimelessCanvas.DataSource

  @statuses [:ok, :warning, :error, :unknown]

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
