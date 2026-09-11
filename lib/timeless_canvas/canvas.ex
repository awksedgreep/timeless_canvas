defmodule TimelessCanvas.Canvas do
  @moduledoc """
  Canvas state: holds the viewbox, elements map, connections map, and grid settings.
  Pure data transformations - no side effects.
  """

  alias TimelessCanvas.Canvas.{Connection, Element, ViewBox}

  defstruct view_box: %ViewBox{},
            elements: %{},
            connections: %{},
            variables: %{},
            grid_size: 20,
            grid_visible: true,
            snap_to_grid: true,
            next_id: 1,
            next_conn_id: 1

  @type t :: %__MODULE__{
          view_box: ViewBox.t(),
          elements: %{String.t() => Element.t()},
          connections: %{String.t() => Connection.t()},
          variables: %{String.t() => map()},
          grid_size: pos_integer(),
          grid_visible: boolean(),
          snap_to_grid: boolean(),
          next_id: pos_integer(),
          next_conn_id: pos_integer()
        }

  @doc """
  Create a new canvas with optional overrides.
  """
  def new(opts \\ []) do
    canvas = struct(__MODULE__, opts)

    grid_size =
      if is_number(canvas.grid_size) and canvas.grid_size > 0, do: canvas.grid_size, else: 20

    %{
      canvas
      | grid_size: grid_size,
        next_id: next_counter(canvas.elements, canvas.next_id, "el-"),
        next_conn_id: next_counter(canvas.connections, canvas.next_conn_id, "conn-")
    }
  end

  # --- Elements ---

  @doc """
  Add an element to the canvas. Assigns an auto-incrementing ID.
  Returns `{canvas, element}`.
  """
  def add_element(%__MODULE__{} = canvas, attrs \\ %{}) do
    counter = next_counter(canvas.elements, canvas.next_id, "el-")
    id = "el-#{counter}"

    element =
      attrs
      |> Element.normalize_attrs()
      |> Map.put(:id, id)
      |> Element.new()
      |> maybe_snap(canvas)

    canvas = %{
      canvas
      | elements: Map.put(canvas.elements, id, element),
        next_id: counter + 1
    }

    {canvas, element}
  end

  @doc """
  Move an element by (dx, dy).
  """
  def move_element(%__MODULE__{} = canvas, id, dx, dy) do
    case Map.get(canvas.elements, id) do
      nil ->
        canvas

      element ->
        moved = Element.move(element, dx, dy) |> maybe_snap(canvas)
        %{canvas | elements: Map.put(canvas.elements, id, moved)}
    end
  end

  @doc """
  Resize an element to new dimensions.
  """
  def resize_element(%__MODULE__{} = canvas, id, width, height) do
    case Map.get(canvas.elements, id) do
      nil ->
        canvas

      element ->
        resized = Element.resize(element, width, height) |> maybe_snap_size(canvas)
        %{canvas | elements: Map.put(canvas.elements, id, resized)}
    end
  end

  @doc """
  Update an element's attributes by ID. Attrs is a map of field => value.
  """
  def update_element(%__MODULE__{} = canvas, id, attrs) when is_map(attrs) do
    case Map.get(canvas.elements, id) do
      nil ->
        canvas

      element ->
        safe_attrs = attrs |> Element.normalize_attrs() |> Map.drop([:id])

        updated =
          element
          |> Map.from_struct()
          |> Map.merge(safe_attrs)
          |> Element.new()
          |> maybe_snap(canvas)

        %{canvas | elements: Map.put(canvas.elements, id, updated)}
    end
  end

  @doc """
  Remove an element by ID. Cascade-deletes any connections referencing it.
  """
  def remove_element(%__MODULE__{} = canvas, id) do
    connections =
      canvas.connections
      |> Map.reject(fn {_cid, conn} ->
        conn.source_id == id or conn.target_id == id
      end)

    %{canvas | elements: Map.delete(canvas.elements, id), connections: connections}
  end

  @doc """
  Duplicate elements into the canvas with new IDs, offset positions, and status reset to :unknown.
  `templates` is a list of Element structs to clone. Each gets a fresh ID via `add_element/2`.
  Returns `{updated_canvas, new_ids}`.
  """
  def duplicate_elements(%__MODULE__{} = canvas, templates, offset) when is_list(templates) do
    {canvas, ids} =
      Enum.reduce(templates, {canvas, []}, fn template, {acc_canvas, acc_ids} ->
        attrs = %{
          type: template.type,
          x: template.x + offset,
          y: template.y + offset,
          width: template.width,
          height: template.height,
          label: template.label,
          color: template.color,
          meta: template.meta,
          pins: template.pins,
          z_index: template.z_index,
          status: :unknown
        }

        {new_canvas, new_el} = add_element(acc_canvas, attrs)
        {new_canvas, [new_el.id | acc_ids]}
      end)

    {canvas, Enum.reverse(ids)}
  end

  @doc """
  Move multiple elements by (dx, dy). Elements not found are skipped.
  """
  def move_elements(%__MODULE__{} = canvas, ids, dx, dy) do
    Enum.reduce(ids, canvas, fn id, acc -> move_element(acc, id, dx, dy) end)
  end

  @doc """
  Remove multiple elements by ID. Cascade-deletes connections for each.
  """
  def remove_elements(%__MODULE__{} = canvas, ids) do
    Enum.reduce(ids, canvas, fn id, acc -> remove_element(acc, id) end)
  end

  @doc """
  Set an element's status. This is ephemeral (not undoable).
  """
  def set_element_status(%__MODULE__{} = canvas, id, status)
      when status in [:ok, :warning, :error, :unknown] do
    case Map.get(canvas.elements, id) do
      nil -> canvas
      element -> %{canvas | elements: Map.put(canvas.elements, id, %{element | status: status})}
    end
  end

  # --- Connections ---

  @doc """
  Add a connection between two elements. Validates both exist.
  Returns `{canvas, connection}`.
  """
  def add_connection(%__MODULE__{} = canvas, source_id, target_id, attrs \\ %{}) do
    duplicate? =
      Enum.any?(canvas.connections, fn {_id, conn} ->
        conn.source_id == source_id and conn.target_id == target_id
      end)

    if source_id != target_id and not duplicate? and Map.has_key?(canvas.elements, source_id) and
         Map.has_key?(canvas.elements, target_id) do
      counter = next_counter(canvas.connections, canvas.next_conn_id, "conn-")
      id = "conn-#{counter}"

      conn =
        struct(
          Connection,
          Map.merge(normalize_connection_attrs(attrs), %{
            id: id,
            source_id: source_id,
            target_id: target_id
          })
        )

      canvas = %{
        canvas
        | connections: Map.put(canvas.connections, id, conn),
          next_conn_id: counter + 1
      }

      {canvas, conn}
    else
      {canvas, nil}
    end
  end

  @doc """
  Remove a connection by ID.
  """
  def remove_connection(%__MODULE__{} = canvas, id) do
    %{canvas | connections: Map.delete(canvas.connections, id)}
  end

  @doc """
  Update a connection's attributes by ID.
  """
  def update_connection(%__MODULE__{} = canvas, id, attrs) when is_map(attrs) do
    case Map.get(canvas.connections, id) do
      nil ->
        canvas

      conn ->
        updated =
          struct(
            conn,
            normalize_connection_attrs(attrs) |> Map.drop([:id, :source_id, :target_id])
          )

        %{canvas | connections: Map.put(canvas.connections, id, updated)}
    end
  end

  @doc """
  All connections touching an element (as source or target).
  """
  def connections_for_element(%__MODULE__{} = canvas, element_id) do
    canvas.connections
    |> Map.values()
    |> Enum.filter(fn conn ->
      conn.source_id == element_id or conn.target_id == element_id
    end)
  end

  @doc "Build an element-id to connections index in one pass."
  def connection_index(%__MODULE__{} = canvas) do
    Enum.reduce(canvas.connections, %{}, fn {_id, conn}, index ->
      index
      |> Map.update(conn.source_id, [conn], &[conn | &1])
      |> Map.update(conn.target_id, [conn], &[conn | &1])
    end)
  end

  # --- View ---

  @doc """
  Pan the canvas viewbox by (dx, dy) in SVG coords.
  """
  def pan(%__MODULE__{} = canvas, dx, dy) do
    %{canvas | view_box: ViewBox.pan(canvas.view_box, dx, dy)}
  end

  @doc """
  Zoom the canvas centered on SVG point (cx, cy) by factor.
  """
  def zoom(%__MODULE__{} = canvas, cx, cy, factor) do
    %{canvas | view_box: ViewBox.zoom(canvas.view_box, cx, cy, factor)}
  end

  defp maybe_snap(element, %{snap_to_grid: true, grid_size: gs}) do
    Element.snap_to_grid(element, gs)
  end

  defp maybe_snap(element, _canvas), do: element

  defp maybe_snap_size(element, %{snap_to_grid: true, grid_size: gs}) do
    Element.snap_size_to_grid(element, gs)
  end

  defp maybe_snap_size(element, _canvas), do: element

  defp next_counter(items, requested, prefix) do
    requested = if is_integer(requested) and requested > 0, do: requested, else: 1

    max_existing =
      items
      |> Map.keys()
      |> Enum.reduce(0, fn key, max_id ->
        if is_binary(key) and String.starts_with?(key, prefix) do
          case key |> String.replace_prefix(prefix, "") |> Integer.parse() do
            {id, ""} -> max(id, max_id)
            _ -> max_id
          end
        else
          max_id
        end
      end)

    max(requested, max_existing + 1)
  end

  defp normalize_connection_attrs(attrs) when is_list(attrs),
    do: attrs |> Map.new() |> normalize_connection_attrs()

  defp normalize_connection_attrs(attrs) when is_map(attrs) do
    fields = ~w(id source_id target_id label color style meta)a
    names = Map.new(fields, &{Atom.to_string(&1), &1})

    attrs
    |> Map.new(fn
      {key, value} when is_atom(key) -> {key, value}
      {key, value} when is_binary(key) -> {Map.get(names, key, key), value}
      pair -> pair
    end)
    |> Map.take(fields)
    |> Map.update(:style, :solid, fn style ->
      if style in [:solid, :dashed, :dotted], do: style, else: :solid
    end)
    |> Map.update(:meta, %{}, &if(is_map(&1), do: &1, else: %{}))
  end

  defp normalize_connection_attrs(_attrs), do: %{}
end
