defmodule TimelessCanvas.Canvas.ElementTest do
  use ExUnit.Case, async: true

  alias TimelessCanvas.Canvas.Element

  describe "new/1" do
    test "defaults to a rect" do
      el = Element.new()
      assert el.type == :rect
      assert el.width == 160.0
      assert el.height == 80.0
      assert el.color == "#4a9eff"
      assert el.status == :unknown
      assert el.z_index == 0
      assert el.meta == %{}
      assert el.pins == %{}
    end

    test "applies type defaults" do
      el = Element.new(%{type: :database})
      assert el.width == 100.0
      assert el.height == 120.0
      assert el.color == "#f59e0b"
    end

    test "explicit attrs override type defaults" do
      el = Element.new(%{type: :server, width: 999.0, color: "#000000"})
      assert el.width == 999.0
      assert el.color == "#000000"
      # untouched default from the type
      assert el.height == 100.0
    end

    test "unknown type falls back to rect dimensions but keeps the type" do
      el = Element.new(%{type: :mystery})
      assert el.type == :mystery
      assert el.width == 160.0
      assert el.height == 80.0
    end
  end

  describe "defaults_for/1 and element_types/0" do
    test "returns defaults including the type" do
      assert Element.defaults_for(:queue) == %{
               type: :queue,
               width: 120.0,
               height: 60.0,
               color: "#a855f7"
             }
    end

    test "unknown type gets rect defaults" do
      assert Element.defaults_for(:nope).width == 160.0
      assert Element.defaults_for(:nope).type == :nope
    end

    test "element_types lists all known types" do
      types = Element.element_types()
      assert :rect in types
      assert :graph in types
      assert :log_stream in types
      assert :text_series in types
    end
  end

  describe "meta_fields/1 and pin_dimensions/0" do
    test "returns recommended fields per type" do
      assert "host" in Element.meta_fields(:server)
      assert "metric_name" in Element.meta_fields(:graph)
      assert Element.meta_fields(:unknown_type) == []
    end

    test "pin dimensions" do
      assert Element.pin_dimensions() == [:host, :ifname]
    end
  end

  describe "move/3" do
    test "shifts by dx/dy" do
      el = Element.new(%{x: 10.0, y: 20.0}) |> Element.move(5.0, -30.0)
      assert el.x == 15.0
      assert el.y == -10.0
    end
  end

  describe "resize/3" do
    test "sets new dimensions" do
      el = Element.new() |> Element.resize(320.0, 200.0)
      assert el.width == 320.0
      assert el.height == 200.0
    end

    test "enforces 20x20 minimum" do
      el = Element.new() |> Element.resize(1.0, 0.0)
      assert el.width == 20.0
      assert el.height == 20.0
    end
  end

  describe "snap_to_grid/2" do
    test "rounds position to the nearest grid point" do
      el = Element.new(%{x: 33.0, y: 47.0}) |> Element.snap_to_grid(20)
      assert el.x == 40.0
      assert el.y == 40.0
    end

    test "positions already on the grid are unchanged" do
      el = Element.new(%{x: 60.0, y: 80.0}) |> Element.snap_to_grid(20)
      assert el.x == 60.0
      assert el.y == 80.0
    end
  end

  describe "snap_size_to_grid/2" do
    test "rounds dimensions to the nearest grid multiple" do
      el = Element.new(%{width: 47.0, height: 33.0}) |> Element.snap_size_to_grid(20)
      assert el.width == 40.0
      assert el.height == 40.0
    end

    test "enforces a minimum of one grid unit" do
      el = Element.new(%{width: 5.0, height: 5.0}) |> Element.snap_size_to_grid(20)
      assert el.width == 20
      assert el.height == 20
    end
  end
end
