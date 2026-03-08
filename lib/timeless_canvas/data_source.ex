defmodule TimelessCanvas.DataSource do
  @moduledoc """
  Behaviour that any data backend must implement to feed live status
  into canvas elements.

  Data sources read element metadata (from `element.meta`) to determine
  what to query. Backends that support push use `handle_message/2` to
  translate incoming messages into status/metric updates.

  Time travel: backends implement `status_at/3` to return the status of
  an element at a given point in time, and `time_range/1` to advertise
  how far back their history goes.
  """

  alias TimelessCanvas.Canvas.Element

  @type status :: :ok | :warning | :error | :unknown
  @type element_id :: String.t()

  @callback init(config :: map()) :: {:ok, state :: term()} | {:error, term()}

  @callback status(state :: term(), element :: Element.t()) :: status()

  @callback metric(state :: term(), element :: Element.t(), metric :: String.t()) ::
              {:ok, float()} | :no_data

  @callback subscribe(state :: term(), element :: Element.t()) :: {:ok, state :: term()}

  @callback unsubscribe(state :: term(), element :: Element.t()) :: {:ok, state :: term()}

  @callback handle_message(state :: term(), message :: term()) ::
              {:status, element_id(), status()}
              | {:metric, element_id(), String.t(), float()}
              | :ignore

  @callback metric_at(
              state :: term(),
              element :: Element.t(),
              metric :: String.t(),
              time :: DateTime.t()
            ) :: {:ok, float()} | :no_data

  @callback metric_range(
              state :: term(),
              element :: Element.t(),
              metric :: String.t(),
              from :: DateTime.t(),
              to :: DateTime.t()
            ) :: {:ok, [{integer(), float()}]}

  @callback status_at(state :: term(), element :: Element.t(), time :: DateTime.t()) ::
              status()

  @callback time_range(state :: term()) ::
              {DateTime.t(), DateTime.t()} | :empty

  @callback event_density(
              state :: term(),
              from :: DateTime.t(),
              to :: DateTime.t(),
              buckets :: pos_integer()
            ) :: [non_neg_integer()]

  @callback list_series_for_host(state :: term(), host :: String.t()) ::
              [{String.t(), map()}]

  @callback list_hosts(state :: term()) :: [String.t()]

  @callback metric_metadata(state :: term(), metric_name :: String.t()) ::
              {:ok, %{type: atom(), unit: String.t() | nil, description: String.t() | nil}}
              | {:ok, nil}

  @callback text_metric(state :: term(), element :: Element.t(), metric :: String.t()) ::
              {:ok, String.t()} | :no_data

  @callback text_metric_at(
              state :: term(),
              element :: Element.t(),
              metric :: String.t(),
              time :: DateTime.t()
            ) :: {:ok, String.t()} | :no_data

  @callback list_label_values(state :: term(), label_key :: String.t()) ::
              [String.t()]

  @optional_callbacks [
    event_density: 4,
    list_series_for_host: 2,
    list_hosts: 1,
    list_label_values: 2,
    metric_metadata: 2,
    text_metric: 3,
    text_metric_at: 4
  ]
end
