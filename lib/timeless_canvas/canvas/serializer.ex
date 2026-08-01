defmodule TimelessCanvas.Canvas.Serializer do
  @moduledoc """
  Encode/decode Canvas structs to/from JSON-encodable maps.
  Uses version field for forward compatibility.
  """

  alias TimelessCanvas.Canvas
  alias TimelessCanvas.Canvas.{Connection, Element, ViewBox}

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
    canvas = %Canvas{
      view_box: decode_view_box(data["view_box"]),
      elements: decode_elements(data["elements"] || %{}),
      connections: decode_connections(data["connections"] || %{}),
      grid_size: data["grid_size"] || 20,
      grid_visible: data["grid_visible"] != false,
      snap_to_grid: data["snap_to_grid"] != false,
      next_id: data["next_id"] || 1,
      next_conn_id: data["next_conn_id"] || 1,
      variables: data["variables"] || %{}
    }

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
         "type" => Atom.to_string(el.type),
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
         "style" => Atom.to_string(conn.style),
         "meta" => conn.meta
       }}
    end)
  end

  # --- Private decoders ---

  defp decode_view_box(nil), do: %ViewBox{}

  defp decode_view_box(data) do
    %ViewBox{
      min_x: (data["min_x"] || 0.0) / 1.0,
      min_y: (data["min_y"] || 0.0) / 1.0,
      width: (data["width"] || 2160.0) / 1.0,
      height: (data["height"] || 1440.0) / 1.0
    }
  end

  defp decode_elements(elements) do
    Map.new(elements, fn {id, data} ->
      el = %Element{
        id: data["id"] || id,
        type: safe_atom(data["type"], :rect),
        x: (data["x"] || 0.0) / 1.0,
        y: (data["y"] || 0.0) / 1.0,
        width: (data["width"] || 160.0) / 1.0,
        height: (data["height"] || 80.0) / 1.0,
        label: data["label"] || "",
        color: data["color"] || "#4a9eff",
        meta: data["meta"] || %{},
        pins: migrate_pins(data["pins"] || %{}, data["meta"] || %{}),
        status: :unknown,
        z_index: data["z_index"] || 0
      }

      {id, el}
    end)
  end

  defp decode_connections(connections) do
    Map.new(connections, fn {id, data} ->
      conn = %Connection{
        id: data["id"] || id,
        source_id: data["source_id"],
        target_id: data["target_id"],
        label: data["label"] || "",
        color: data["color"] || "#8888aa",
        style: safe_atom(data["style"], :solid),
        meta: data["meta"] || %{}
      }

      {id, conn}
    end)
  end

  defp safe_atom(nil, default), do: default

  defp safe_atom(str, default) when is_binary(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> default
  end

  defp safe_atom(val, _default) when is_atom(val), do: val

  defp derive_pin(val), do: Element.derive_pin(val)

  defp migrate_pins(pins, meta) do
    dims = ~w(host ifname)

    Enum.reduce(dims, pins, fn dim, acc_pins ->
      if Map.has_key?(acc_pins, dim) do
        acc_pins
      else
        Map.put(acc_pins, dim, derive_pin(meta[dim]))
      end
    end)
  end
end
