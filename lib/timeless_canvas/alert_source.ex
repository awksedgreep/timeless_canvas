defmodule TimelessCanvas.AlertSource do
  @moduledoc """
  Behaviour for the alerting backend behind a canvas element.

  The canvas knows which metric and labels an element selects; it does not
  know how alert rules are stored or evaluated, and must not — that lives in
  whatever telemetry stack the canvas is embedded in. An implementation is
  configured as:

      config :timeless_canvas, :alert_backend, MyApp.AlertBackend

  When nothing is configured the alert controls do not render at all, which
  is the honest presentation: a form that accepted rules nothing would store
  is worse than no form.

  ## Selectors come from the element

  Callbacks take the `Element` itself, not a metric and labels, mirroring
  `c:TimelessCanvas.DataSource.metric_range/5`. Which labels a graph actually
  queries is the backend's decision — it drops presentation keys and applies
  the series filter — so a canvas that re-derived them could silently create a
  rule watching a different series than the graph draws. Handing over the
  element makes that divergence impossible: the rule is scoped by exactly the
  selector that produced the picture.
  """

  alias TimelessCanvas.Canvas.Element

  @type rule :: %{
          required(:id) => term(),
          required(:name) => String.t(),
          required(:metric) => String.t(),
          required(:labels) => map(),
          required(:condition) => String.t(),
          required(:threshold) => number(),
          required(:duration) => non_neg_integer(),
          required(:aggregate) => String.t(),
          required(:enabled) => boolean(),
          optional(:webhook_url) => String.t() | nil,
          optional(:webhook_format) => String.t() | nil
        }

  @doc "Rules scoped to what this element selects."
  @callback list_rules(element :: Element.t()) :: {:ok, [rule()]} | {:error, term()}

  @doc """
  Create a rule scoped to this element.

  `attrs` carries only what the user chose — condition, threshold, duration,
  aggregate, delivery. Metric and labels are derived from the element by the
  backend, never taken from `attrs`.
  """
  @callback create_rule(element :: Element.t(), attrs :: map()) ::
              {:ok, term()} | {:error, term()}

  @callback update_rule(id :: term(), attrs :: map()) :: :ok | {:error, term()}

  @callback delete_rule(id :: term()) :: :ok | {:error, term()}

  @doc """
  Delivery formats this backend can send, as `{value, label}` pairs.

  Offered rather than assumed: posting a generic JSON body to an ntfy topic
  makes ntfy render the raw JSON as the message text, so the format has to be
  an explicit choice at rule creation, not a default nobody sees.
  """
  @callback delivery_formats() :: [{String.t(), String.t()}]

  @optional_callbacks [delivery_formats: 0]

  @doc "The configured backend, or nil when alerting is not wired up."
  def backend, do: Application.get_env(:timeless_canvas, :alert_backend)

  @doc false
  def configured?, do: backend() != nil
end
