defmodule TimelessCanvas.DataSource.Stub do
  @moduledoc """
  No-op data source that returns `:unknown` for all elements.
  Ships with TimelessCanvas so the canvas works without any backend configured.
  """

  @behaviour TimelessCanvas.DataSource

  @impl true
  def init(_config), do: {:ok, %{}}

  @impl true
  def status(_state, _element), do: :unknown

  @impl true
  def metric(_state, _element, _metric), do: :no_data

  @impl true
  def subscribe(state, _element), do: {:ok, state}

  @impl true
  def unsubscribe(state, _element), do: {:ok, state}

  @impl true
  def handle_message(_state, _message), do: :ignore

  @impl true
  def metric_at(_state, _element, _metric, _time), do: :no_data

  @impl true
  def metric_range(_state, _element, _metric, _from, _to), do: {:ok, []}

  @impl true
  def status_at(_state, _element, _time), do: :unknown

  @impl true
  def time_range(_state), do: :empty
end
