defmodule TimelessCanvas.Canvas.Serializer do
  @moduledoc """
  Encode/decode Canvas structs to/from JSON-encodable maps.
  Uses version field for forward compatibility.
  """

  alias TimelessCanvas.Canvas
  alias TimelessCanvas.Canvas.{Connection, Element, ViewBox}
  require Logger

  @version 2

  @doc """
  Encode a Canvas struct to a JSON-encodable map.
  """
  def encode(%Canvas{} = canvas) do
    %{
      "version" => @version,
      "view_box" => encode_view_box(canvas.view_box),
      "elements" => encode_elements(canvas.elements),
      "connections" => encode_connections(canvas.connections),
      "grid_size" => canvas.grid_size,
      "grid_visible" => canvas.grid_visible,
      "snap_to_grid" => canvas.snap_to_grid,
      "next_id" => canvas.next_id,
      "next_conn_id" => canvas.next_conn_id,
      "variables" => canvas.variables
    }
  end

  @doc """
  Decode a map (from JSON) back to a Canvas struct.
  Returns `{:ok, canvas}` or `{:error, reason}`.

  `nil` and the empty map decode to a fresh `Canvas`: `create_canvas`
  persists `%{}` as the initial blob, so explicitly-empty data is a
  brand-new canvas, not corruption. Non-empty data with a missing or
  unsupported version is still an error so callers can protect the
  stored blob instead of overwriting it.
  """
  def decode(nil), do: {:ok, Canvas.new()}
  def decode(data) when data == %{}, do: {:ok, Canvas.new()}

  def decode(%{"version" => version} = data) when version in [1, 2] do
    unless is_map(data["elements"] || %{}) and is_map(data["connections"] || %{}) do
      raise ArgumentError, "elements and connections must be maps"
    end

    elements = decode_elements(data["elements"] || %{})

    connections =
      (data["connections"] || %{})
      |> decode_connections()
      |> Map.filter(fn {_id, conn} ->
        Map.has_key?(elements, conn.source_id) and Map.has_key?(elements, conn.target_id)
      end)

    canvas =
      Canvas.new(
        view_box: decode_view_box(data["view_box"]),
        elements: elements,
        connections: connections,
        grid_size: positive_number(data["grid_size"], 20),
        grid_visible: data["grid_visible"] != false,
        snap_to_grid: data["snap_to_grid"] != false,
        next_id: positive_integer(data["next_id"], 1),
        next_conn_id: positive_integer(data["next_conn_id"], 1),
        variables: if(is_map(data["variables"]), do: data["variables"], else: %{})
      )

    {:ok, canvas}
  rescue
    e -> {:error, Exception.message(e)}
  end

  def decode(_data), do: {:error, "unsupported version"}

  # --- Private encoders ---

  defp encode_view_box(%ViewBox{} = vb) do
    %{"min_x" => vb.min_x, "min_y" => vb.min_y, "width" => vb.width, "height" => vb.height}
  end

  defp encode_elements(elements) do
    Map.new(elements, fn {id, el} ->
      {id,
       %{
         "id" => el.id,
         "type" => to_string_safe(el.type, "rect"),
         "x" => el.x,
         "y" => el.y,
         "width" => el.width,
         "height" => el.height,
         "label" => el.label,
         "color" => el.color,
         "meta" => el.meta,
         "pins" => el.pins,
         "z_index" => el.z_index
       }}
    end)
  end

  defp encode_connections(connections) do
    Map.new(connections, fn {id, conn} ->
      {id,
       %{
         "id" => conn.id,
         "source_id" => conn.source_id,
         "target_id" => conn.target_id,
         "label" => conn.label,
         "color" => conn.color,
         "style" => to_string_safe(conn.style, "solid"),
         "meta" => conn.meta
       }}
    end)
  end

  # --- Private decoders ---

  defp decode_view_box(nil), do: %ViewBox{}

  defp decode_view_box(data) do
    %ViewBox{
      min_x: number(data["min_x"], 0.0),
      min_y: number(data["min_y"], 0.0),
      width: positive_number(data["width"], 2160.0),
      height: positive_number(data["height"], 1440.0)
    }
  end

  defp decode_elements(elements) when is_map(elements) do
    Enum.reduce(elements, %{}, fn
      {id, data}, acc when is_binary(id) and is_map(data) ->
        case decode_element(id, data) do
          {:ok, element} ->
            Map.put(acc, id, element)

          :error ->
            Logger.warning("Skipping invalid canvas element #{inspect(id)} while decoding")
            acc
        end

      {id, _data}, acc ->
        Logger.warning("Skipping invalid canvas element #{inspect(id)} while decoding")
        acc
    end)
  end

  defp decode_elements(_elements), do: %{}

  defp decode_element(id, data) do
    with {:ok, type} <- safe_element_type(data["type"]) do
      {:ok,
       Element.new(%{
         id: id,
         type: type,
         x: number(data["x"], 0.0),
         y: number(data["y"], 0.0),
         width: positive_number(data["width"], Element.defaults_for(type).width),
         height: positive_number(data["height"], Element.defaults_for(type).height),
         label: if(is_binary(data["label"]), do: data["label"], else: ""),
         color: if(is_binary(data["color"]), do: data["color"], else: "#4a9eff"),
         meta: if(is_map(data["meta"]), do: data["meta"], else: %{}),
         pins: migrate_pins(data["pins"], data["meta"]),
         status: :unknown,
         z_index: integer(data["z_index"], 0)
       })}
    end
  end

  defp decode_connections(connections) when is_map(connections) do
    Enum.reduce(connections, %{}, fn
      {id, data}, acc when is_binary(id) and is_map(data) ->
        conn = %Connection{
          id: id,
          source_id: data["source_id"],
          target_id: data["target_id"],
          label: if(is_binary(data["label"]), do: data["label"], else: ""),
          color: if(is_binary(data["color"]), do: data["color"], else: "#8888aa"),
          style: safe_connection_style(data["style"]),
          meta: if(is_map(data["meta"]), do: data["meta"], else: %{})
        }

        Map.put(acc, id, conn)

      {id, _data}, acc ->
        Logger.warning("Skipping invalid canvas connection #{inspect(id)} while decoding")
        acc
    end)
  end

  defp decode_connections(_connections), do: %{}

  defp safe_element_type(nil), do: {:ok, :rect}

  defp safe_element_type(type) when is_atom(type) do
    if type in Element.element_types(), do: {:ok, type}, else: :error
  end

  defp safe_element_type(type) when is_binary(type) do
    case Enum.find(Element.element_types(), &(Atom.to_string(&1) == type)) do
      nil -> :error
      known -> {:ok, known}
    end
  end

  defp safe_element_type(_type), do: :error

  defp safe_connection_style(style) when style in [:solid, :dashed, :dotted], do: style

  defp safe_connection_style(style) when is_binary(style) do
    Enum.find([:solid, :dashed, :dotted], :solid, &(Atom.to_string(&1) == style))
  end

  defp safe_connection_style(_style), do: :solid

  defp derive_pin(val), do: Element.derive_pin(val)

  defp migrate_pins(pins, meta) do
    pins = if is_map(pins), do: pins, else: %{}
    meta = if is_map(meta), do: meta, else: %{}
    dims = ~w(host ifname)

    Enum.reduce(dims, pins, fn dim, acc_pins ->
      if Map.has_key?(acc_pins, dim) do
        acc_pins
      else
        Map.put(acc_pins, dim, derive_pin(meta[dim]))
      end
    end)
  end

  defp to_string_safe(value, _default) when is_atom(value), do: Atom.to_string(value)
  defp to_string_safe(value, _default) when is_binary(value), do: value
  defp to_string_safe(_value, default), do: default

  defp number(value, _default) when is_integer(value), do: value / 1
  defp number(value, _default) when is_float(value), do: value

  defp number(value, default) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} -> parsed
      _ -> default
    end
  end

  defp number(_value, default), do: default

  defp positive_number(value, default) do
    case number(value, default) do
      parsed when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp integer(value, _default) when is_integer(value), do: value

  defp integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> default
    end
  end

  defp integer(_value, default), do: default

  defp positive_integer(value, default) do
    case integer(value, default) do
      parsed when parsed > 0 -> parsed
      _ -> default
    end
  end
end
