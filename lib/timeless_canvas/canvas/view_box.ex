defmodule TimelessCanvas.Canvas.ViewBox do
  @moduledoc """
  ViewBox struct representing the visible area of the SVG canvas.
  Handles pan and zoom math in SVG coordinate space.
  """

  defstruct min_x: 0.0, min_y: 0.0, width: 1200.0, height: 800.0

  @type t :: %__MODULE__{
          min_x: float(),
          min_y: float(),
          width: float(),
          height: float()
        }

  @min_width 100.0
  @max_width 50_000.0

  @doc """
  Formats the viewBox for the SVG `viewBox` attribute.
  """
  def to_string(%__MODULE__{} = vb) do
    [vb.min_x, vb.min_y, vb.width, vb.height]
    |> Enum.map_join(" ", &format_float/1)
  end

  defp format_float(f) when is_float(f) do
    :erlang.float_to_binary(f, [:compact, decimals: 4])
  end

  @doc """
  Pan the viewbox by (dx, dy) in SVG coordinate space.
  """
  def pan(%__MODULE__{} = vb, dx, dy) do
    %{vb | min_x: vb.min_x + dx, min_y: vb.min_y + dy}
  end

  @doc """
  Zoom centered on SVG point (cx, cy) by the given factor.
  Factor < 1 zooms in, factor > 1 zooms out.
  Keeps the point under the cursor stationary.
  """
  def zoom(%__MODULE__{} = vb, cx, cy, factor) do
    new_width = vb.width * factor
    new_height = vb.height * factor

    cond do
      new_width < @min_width ->
        vb

      new_width > @max_width ->
        vb

      true ->
        %{
          vb
          | min_x: cx - (cx - vb.min_x) * factor,
            min_y: cy - (cy - vb.min_y) * factor,
            width: new_width,
            height: new_height
        }
    end
  end

  @doc """
  Convert client pixel coordinates to SVG coordinates.
  `client_x`, `client_y` are pixel positions relative to the SVG element.
  `client_width`, `client_height` are the SVG element's pixel dimensions.
  """
  def client_to_svg(%__MODULE__{} = vb, client_x, client_y, client_width, client_height) do
    svg_x = vb.min_x + client_x * (vb.width / client_width)
    svg_y = vb.min_y + client_y * (vb.height / client_height)
    {svg_x, svg_y}
  end
end
