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

  @doc """
  Create a new element with type defaults merged with caller attrs.
  Attrs with explicit values override type defaults.
  """
  def new(attrs \\ %{}) do
    type = Map.get(attrs, :type, :rect)
    defaults = defaults_for(type)
    merged = Map.merge(defaults, attrs)
    struct!(__MODULE__, merged)
  end

  @doc """
  Returns list of all available element type atoms.
  """
  def element_types, do: Map.keys(@element_types)

  @doc """
  Returns the default attributes for a given element type.
  Falls back to :rect defaults for unknown types.
  """
  def defaults_for(type) do
    Map.get(@element_types, type, @element_types[:rect])
    |> Map.put(:type, type)
  end

  @meta_fields %{
    rect: ~w(image_url),
    server: ~w(host ip os role),
    service: ~w(service_name version port),
    database: ~w(engine host port db_name),
    load_balancer: ~w(host algorithm port),
    queue: ~w(broker queue_name host),
    cache: ~w(engine host port),
    router: ~w(host ip os role),
    network: ~w(host cidr vlan),
    graph: ~w(host metric_name y_min y_max),
    log_stream: ~w(level metadata_filter),
    trace_stream: ~w(service name kind),
    canvas: ~w(canvas_id),
    text: ~w(font_size),
    text_series: ~w(host metric_name)
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
    %{el | x: el.x + dx, y: el.y + dy}
  end

  @doc """
  Resize element to new width and height. Enforces minimum 20x20.
  """
  def resize(%__MODULE__{} = el, width, height) do
    %{el | width: max(width, 20.0), height: max(height, 20.0)}
  end

  @doc """
  Snap element position to the nearest grid point.
  """
  def snap_to_grid(%__MODULE__{} = el, grid_size) when grid_size > 0 do
    %{
      el
      | x: Float.round(el.x / grid_size) * grid_size,
        y: Float.round(el.y / grid_size) * grid_size
    }
  end

  @doc """
  Snap element dimensions to the nearest grid multiple. Enforces minimum one grid unit.
  """
  def snap_size_to_grid(%__MODULE__{} = el, grid_size) when grid_size > 0 do
    %{
      el
      | width: max(Float.round(el.width / grid_size) * grid_size, grid_size),
        height: max(Float.round(el.height / grid_size) * grid_size, grid_size)
    }
  end
end
