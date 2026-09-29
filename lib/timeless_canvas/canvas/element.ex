defmodule TimelessCanvas.Canvas.Element do
  @moduledoc """
  An element on the canvas. Has position, size, label, color, type, and metadata.
  """

  defstruct [
    :id,
    type: :rect,
    x: 0.0,
    y: 0.0,
    width: 160.0,
    height: 80.0,
    label: "",
    color: "#4a9eff",
    meta: %{},
    pins: %{},
    status: :unknown,
    z_index: 0
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          type: atom(),
          x: float(),
          y: float(),
          width: float(),
          height: float(),
          label: String.t(),
          color: String.t(),
          meta: map(),
          pins: map(),
          status: :ok | :warning | :error | :unknown,
          z_index: integer()
        }

  @element_types %{
    rect: %{width: 160.0, height: 80.0, color: "#4a9eff"},
    server: %{width: 120.0, height: 100.0, color: "#6366f1"},
    service: %{width: 140.0, height: 70.0, color: "#22c55e"},
    database: %{width: 100.0, height: 120.0, color: "#f59e0b"},
    load_balancer: %{width: 140.0, height: 70.0, color: "#06b6d4"},
    queue: %{width: 120.0, height: 60.0, color: "#a855f7"},
    cache: %{width: 100.0, height: 80.0, color: "#ef4444"},
    router: %{width: 100.0, height: 100.0, color: "#f97316"},
    network: %{width: 160.0, height: 60.0, color: "#64748b"},
    graph: %{width: 220.0, height: 100.0, color: "#0ea5e9"},
    log_stream: %{width: 280.0, height: 80.0, color: "#10b981"},
    trace_stream: %{width: 280.0, height: 80.0, color: "#8b5cf6"},
    canvas: %{width: 140.0, height: 100.0, color: "#818cf8"},
    text: %{width: 200.0, height: 40.0, color: "#e2e8f0"},
    text_series: %{width: 200.0, height: 60.0, color: "#14b8a6"},
    top_n: %{width: 260.0, height: 170.0, color: "#f43f5e"}
  }

  @pin_dimensions ~w(host ifname)a
  @fields ~w(id type x y width height label color meta pins status z_index)a
  @field_names Map.new(@fields, &{Atom.to_string(&1), &1})

  @doc """
  Pin dimensions for host and interface pinning.
  """
  def pin_dimensions, do: @pin_dimensions

  @doc """
  Derive a pin from a raw meta value: empty → none, `$var` → variable,
  anything else → literal.
  """
  def derive_pin(val) do
    cond do
      is_nil(val) or val == "" ->
        %{"mode" => "none", "value" => ""}

      is_binary(val) and String.starts_with?(val, "$") ->
        %{"mode" => "variable", "value" => val}

      true ->
        %{"mode" => "literal", "value" => to_string(val)}
    end
  end

  @doc """
  Create a new element with type defaults merged with caller attrs.
  Attrs with explicit values override type defaults.
  """
  def new(attrs \\ %{}) do
    attrs = normalize_attrs(attrs)
    type = normalize_type(Map.get(attrs, :type, :rect))
    defaults = defaults_for(type)

    merged =
      defaults
      |> Map.merge(attrs)
      |> Map.put(:type, type)
      |> Map.update(:meta, %{}, &if(is_map(&1), do: &1, else: %{}))
      |> Map.update(:pins, %{}, &if(is_map(&1), do: &1, else: %{}))
      |> normalize_geometry(defaults)

    struct(__MODULE__, merged)
  end

  @doc false
  def normalize_attrs(attrs) when is_list(attrs), do: attrs |> Map.new() |> normalize_attrs()

  def normalize_attrs(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {key, value} when is_atom(key) -> {key, value}
      {key, value} when is_binary(key) -> {Map.get(@field_names, key, key), value}
      pair -> pair
    end)
    |> Map.take(@fields)
  end

  def normalize_attrs(_attrs), do: %{}

  @doc false
  def normalize_type(type) when is_atom(type) do
    if type in element_types(), do: type, else: :rect
  end

  def normalize_type(type) when is_binary(type) do
    Enum.find(element_types(), :rect, &(Atom.to_string(&1) == type))
  end

  def normalize_type(_type), do: :rect

  @doc """
  Returns list of all available element type atoms.
  """
  def element_types, do: Map.keys(@element_types)

  @doc """
  Returns the default attributes for a given element type.
  Falls back to :rect defaults for unknown types.
  """
  def defaults_for(type) do
    normalized = normalize_type(type)

    Map.fetch!(@element_types, normalized)
    |> Map.put(:type, normalized)
  end

  @meta_fields %{
    rect: ~w(image_url),
    server: ~w(host ip os role os_icon),
    service: ~w(service_name version port icon),
    database: ~w(engine host port db_name icon),
    load_balancer: ~w(host algorithm port icon),
    queue: ~w(broker queue_name host icon),
    cache: ~w(engine host port icon),
    router: ~w(host ip os role os_icon),
    network: ~w(host cidr vlan icon),
    graph: ~w(host metric_name label_filter aggregate window y_min y_max icon),
    log_stream: ~w(host level metadata_filter),
    trace_stream: ~w(host service name kind),
    canvas: ~w(canvas_id),
    text: ~w(font_size),
    text_series: ~w(host metric_name icon),
    top_n: ~w(host metric_name label_filter group_by limit order aggregate window)
  }

  @doc """
  Returns the recommended metadata field names for a given element type.
  These are advisory - the meta map stays freeform.
  """
  def meta_fields(type) do
    Map.get(@meta_fields, type, [])
  end

  @non_label_meta_keys ~w(
    metric_name series_label_key series_label_value y_min y_max icon os_icon
    aggregate group_by label_filter limit order window
  )

  @doc """
  Meta keys that configure an element rather than select a series.

  Every other meta key is a label filter, so a new display or query option
  must be listed here or it silently narrows the query to nothing.
  """
  def non_label_meta_keys, do: @non_label_meta_keys

  @doc """
  The label filter an element's metric queries use, derived from its meta.

  Accepts an element or a bare meta map. Blank values are dropped, and a
  `series_label_key`/`series_label_value` pair is applied as one more label.
  Data sources should call this rather than deriving labels themselves, so
  the properties panel and the query agree on what is being selected.
  """
  def query_labels(%__MODULE__{meta: meta}), do: query_labels(meta)

  def query_labels(meta) when is_map(meta) do
    labels =
      meta
      |> Map.drop(@non_label_meta_keys)
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    case {meta["series_label_key"], meta["series_label_value"]} do
      {key, value} when is_binary(key) and key != "" and is_binary(value) and value != "" ->
        Map.put(labels, key, value)

      _ ->
        labels
    end
  end

  def query_labels(_meta), do: %{}

  @doc """
  What an element's `label_filter` adds to its labels: the things equality
  on one value cannot say.

  The filter is a comma-separated list of `key=value` and `key!=value`, and
  a value may be several joined by `|`:

      kind!=slice|manager, comm=postgres|pgbouncer

  Returns `[{key, :eq | :neq, [value]}]`. Terms that do not parse are left
  out, so a filter half typed narrows nothing rather than everything.
  """
  def label_filter(%__MODULE__{meta: meta}), do: label_filter(meta)

  def label_filter(%{"label_filter" => filter}) when is_binary(filter) do
    filter
    |> String.split(",")
    |> Enum.flat_map(&parse_matcher/1)
    |> Enum.group_by(fn {key, op, _values} -> {key, op} end, fn {_, _, values} -> values end)
    |> Enum.map(fn {{key, op}, values} -> {key, op, values |> List.flatten() |> Enum.uniq()} end)
    |> Enum.sort()
  end

  def label_filter(_meta), do: []

  @doc """
  Everything an element selects by, as `[{key, :eq | :neq, [value]}]`: its
  labels (`query_labels/1`) and its `label_filter/1`.

  This is what `metric_range/6` and `top_series/5` filter by. A backend that
  can only ask what a label equals cannot honour it, and should not export
  them.
  """
  def query_matchers(element_or_meta) do
    labels =
      for {key, value} <- element_or_meta |> query_labels() |> Enum.sort(),
          do: {key, :eq, [to_string(value)]}

    labels ++ label_filter(element_or_meta)
  end

  @doc """
  Whether a series' labels satisfy a list of matchers. A label the series
  does not carry is not equal to anything, so it passes every `:neq`.
  """
  def matches?(labels, matchers) when is_map(labels) and is_list(matchers) do
    Enum.all?(matchers, fn
      {key, :eq, values} -> to_string(Map.get(labels, key, "")) in values
      {key, :neq, values} -> to_string(Map.get(labels, key, "")) not in values
    end)
  end

  defp parse_matcher(term) do
    with [_, key, op, values] <- Regex.run(~r/^\s*([^=!\s]+)\s*(!=|=)(.*)$/s, term),
         [_ | _] = values <-
           values |> String.split("|") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) do
      [{key, if(op == "=", do: :eq, else: :neq), values}]
    else
      _ -> []
    end
  end

  @doc """
  Move element by (dx, dy).
  """
  def move(%__MODULE__{} = el, dx, dy) do
    with {:ok, x} <- number(el.x),
         {:ok, y} <- number(el.y),
         {:ok, dx} <- number(dx),
         {:ok, dy} <- number(dy) do
      %{el | x: x + dx, y: y + dy}
    else
      _ -> el
    end
  end

  @doc """
  Resize element to new width and height. Enforces minimum 20x20.
  """
  def resize(%__MODULE__{} = el, width, height) do
    with {:ok, width} <- number(width), {:ok, height} <- number(height) do
      %{el | width: max(width, 20.0), height: max(height, 20.0)}
    else
      _ -> el
    end
  end

  @doc """
  Snap element position to the nearest grid point.
  """
  def snap_to_grid(%__MODULE__{} = el, grid_size) when grid_size > 0 do
    with {:ok, x} <- number(el.x),
         {:ok, y} <- number(el.y),
         {:ok, grid_size} <- number(grid_size) do
      %{el | x: Float.round(x / grid_size) * grid_size, y: Float.round(y / grid_size) * grid_size}
    else
      _ -> el
    end
  end

  def snap_to_grid(%__MODULE__{} = el, _grid_size), do: el

  @doc """
  Snap element dimensions to the nearest grid multiple. Enforces minimum one grid unit.
  """
  def snap_size_to_grid(%__MODULE__{} = el, grid_size) when grid_size > 0 do
    with {:ok, width} <- number(el.width),
         {:ok, height} <- number(el.height),
         {:ok, grid_size} <- number(grid_size) do
      %{
        el
        | width: max(Float.round(width / grid_size) * grid_size, grid_size),
          height: max(Float.round(height / grid_size) * grid_size, grid_size)
      }
    else
      _ -> el
    end
  end

  def snap_size_to_grid(%__MODULE__{} = el, _grid_size), do: el

  defp normalize_geometry(attrs, defaults) do
    attrs
    |> Map.put(:x, number_or(Map.get(attrs, :x), 0.0))
    |> Map.put(:y, number_or(Map.get(attrs, :y), 0.0))
    |> Map.put(:width, number_or(Map.get(attrs, :width), defaults.width))
    |> Map.put(:height, number_or(Map.get(attrs, :height), defaults.height))
  end

  defp number(value) when is_integer(value), do: {:ok, value / 1}
  defp number(value) when is_float(value), do: {:ok, value}

  defp number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> {:ok, number}
      _ -> :error
    end
  end

  defp number(_value), do: :error

  defp number_or(value, default) do
    case number(value) do
      {:ok, number} -> number
      :error -> default
    end
  end
end
