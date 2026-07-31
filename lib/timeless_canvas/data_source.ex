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

  ## Bounded discovery queries

  The discovery callbacks (`list_hosts/2`, `list_label_values/3`,
  `list_series_for_host/3`) accept a keyword list of options so backends
  can bound work at the source instead of materializing full universes:

    * `:filter` — `String.t()` or `nil`; case-insensitive substring match
      against the host name, label value, or metric name respectively
    * `:limit` — `pos_integer()`; maximum number of results to return

  Backends should apply the filter first, then the limit.
  `apply_query_opts/3` is provided as a convenience for in-memory backends.

  ## Batch status queries

  `statuses/2` and `statuses_at/3` are optional batch variants of
  `status/2` and `status_at/3`. When exported, callers use them to fetch
  statuses for many elements in one backend round trip; otherwise the
  per-element callbacks are used as a fallback.
  """

  alias TimelessCanvas.Canvas.Element

  @type status :: :ok | :warning | :error | :unknown
  @type element_id :: String.t()
  @type query_opts :: [filter: String.t() | nil, limit: pos_integer()]

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

  @callback statuses(state :: term(), elements :: [Element.t()]) ::
              %{element_id() => status()}

  @callback statuses_at(state :: term(), elements :: [Element.t()], time :: DateTime.t()) ::
              %{element_id() => status()}

  @callback time_range(state :: term()) ::
              {DateTime.t(), DateTime.t()} | :empty

  @callback event_density(
              state :: term(),
              from :: DateTime.t(),
              to :: DateTime.t(),
              buckets :: pos_integer()
            ) :: [non_neg_integer()]

  @callback list_series_for_host(state :: term(), host :: String.t(), opts :: query_opts()) ::
              [{String.t(), map()}]

  @callback list_hosts(state :: term(), opts :: query_opts()) :: [String.t()]

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

  @callback list_label_values(state :: term(), label_key :: String.t(), opts :: query_opts()) ::
              [String.t()]

  @optional_callbacks [
    event_density: 4,
    list_series_for_host: 3,
    list_hosts: 2,
    list_label_values: 3,
    metric_metadata: 2,
    statuses: 2,
    statuses_at: 3,
    text_metric: 3,
    text_metric_at: 4
  ]

  @doc """
  Applies `:filter` (case-insensitive substring, filter first) and `:limit`
  query options to an in-memory list.

  `name_fun` extracts the string the filter matches against (defaults to
  the item itself).
  """
  @spec apply_query_opts([term()], query_opts(), (term() -> String.t())) :: [term()]
  def apply_query_opts(list, opts, name_fun \\ fn item -> item end) when is_list(list) do
    filter = Keyword.get(opts, :filter)
    limit = Keyword.get(opts, :limit)

    list
    |> filter_by(filter, name_fun)
    |> take_limit(limit)
  end

  defp filter_by(list, nil, _name_fun), do: list
  defp filter_by(list, "", _name_fun), do: list

  defp filter_by(list, filter, name_fun) when is_binary(filter) do
    downcased = String.downcase(filter)
    Enum.filter(list, &String.contains?(String.downcase(name_fun.(&1)), downcased))
  end

  defp take_limit(list, nil), do: list
  defp take_limit(list, limit) when is_integer(limit) and limit > 0, do: Enum.take(list, limit)
end
