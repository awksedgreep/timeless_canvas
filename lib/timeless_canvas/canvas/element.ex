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
    text_series: %{width: 200.0, height: 60.0, color: "#14b8a6"}
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
    graph: ~w(host metric_name y_min y_max icon),
    log_stream: ~w(host level metadata_filter),
    trace_stream: ~w(host service name kind),
    canvas: ~w(canvas_id),
    text: ~w(font_size),
    text_series: ~w(host metric_name icon)
  }

  @doc """
  Returns the recommended metadata field names for a given element type.
  These are advisory - the meta map stays freeform.
  """
  def meta_fields(type) do
    Map.get(@meta_fields, type, [])
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
