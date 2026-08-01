defmodule TimelessCanvas.Canvas.ViewBoxTest do
  use ExUnit.Case, async: true

  alias TimelessCanvas.Canvas.ViewBox

  test "defaults" do
    vb = %ViewBox{}
    assert vb.min_x == 0.0
    assert vb.min_y == 0.0
    assert vb.width == 2160.0
    assert vb.height == 1440.0
  end

  describe "to_string/1" do
    test "formats the SVG viewBox attribute" do
      assert ViewBox.to_string(%ViewBox{}) == "0.0 0.0 2160.0 1440.0"
    end

    test "compacts decimals" do
      vb = %ViewBox{min_x: 10.5, min_y: -3.25, width: 100.0, height: 50.125}
      assert ViewBox.to_string(vb) == "10.5 -3.25 100.0 50.125"
    end
  end

  describe "pan/3" do
    test "shifts the origin without changing dimensions" do
      vb = ViewBox.pan(%ViewBox{}, 100.0, -40.0)
      assert vb.min_x == 100.0
      assert vb.min_y == -40.0
      assert vb.width == 2160.0
      assert vb.height == 1440.0
    end
  end

  describe "zoom/4" do
    test "factor < 1 zooms in around the given point" do
      base = %ViewBox{min_x: 0.0, min_y: 0.0, width: 1200.0, height: 800.0}
      vb = ViewBox.zoom(base, 600.0, 400.0, 0.5)
      assert vb.width == 600.0
      assert vb.height == 400.0
      assert vb.min_x == 300.0
      assert vb.min_y == 200.0
    end

    test "factor > 1 zooms out around the given point" do
      base = %ViewBox{min_x: 0.0, min_y: 0.0, width: 1200.0, height: 800.0}
      vb = ViewBox.zoom(base, 0.0, 0.0, 2.0)
      assert vb.width == 2400.0
      assert vb.height == 1600.0
      assert vb.min_x == 0.0
      assert vb.min_y == 0.0
    end

    test "keeps the zoom center stationary" do
      vb = %ViewBox{min_x: 100.0, min_y: 50.0, width: 1000.0, height: 500.0}
      {cx, cy} = {350.0, 175.0}

      zoomed = ViewBox.zoom(vb, cx, cy, 0.5)

      # The relative position of (cx, cy) within the box is preserved
      assert (cx - zoomed.min_x) / zoomed.width == (cx - vb.min_x) / vb.width
      assert (cy - zoomed.min_y) / zoomed.height == (cy - vb.min_y) / vb.height
    end

    test "clamps below the minimum width" do
      vb = %ViewBox{width: 150.0, height: 100.0}
      assert ViewBox.zoom(vb, 0.0, 0.0, 0.5) == vb
    end

    test "clamps above the maximum width" do
      vb = %ViewBox{width: 40_000.0, height: 20_000.0}
      assert ViewBox.zoom(vb, 0.0, 0.0, 2.0) == vb
    end
  end

  describe "client_to_svg/5" do
    test "maps client pixels to SVG coordinates" do
      vb = %ViewBox{min_x: 0.0, min_y: 0.0, width: 1200.0, height: 800.0}
      assert ViewBox.client_to_svg(vb, 600.0, 400.0, 1200.0, 800.0) == {600.0, 400.0}
    end

    test "accounts for the view box origin and scale" do
      vb = %ViewBox{min_x: 100.0, min_y: 200.0, width: 600.0, height: 400.0}
      # Client is twice the resolution of the view box
      assert ViewBox.client_to_svg(vb, 300.0, 200.0, 1200.0, 800.0) == {250.0, 300.0}
    end
  end
end
