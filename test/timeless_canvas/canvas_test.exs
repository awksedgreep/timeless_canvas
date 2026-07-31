defmodule TimelessCanvas.CanvasTest do
  use ExUnit.Case, async: true

  alias TimelessCanvas.Canvas
  alias TimelessCanvas.Canvas.ViewBox

  defp bare_canvas, do: Canvas.new(snap_to_grid: false)

  describe "new/1" do
    test "builds a canvas with defaults" do
      canvas = Canvas.new()

      assert canvas.elements == %{}
      assert canvas.connections == %{}
      assert canvas.variables == %{}
      assert canvas.grid_size == 20
      assert canvas.grid_visible
      assert canvas.snap_to_grid
      assert canvas.next_id == 1
      assert canvas.next_conn_id == 1
      assert %ViewBox{} = canvas.view_box
    end

    test "accepts overrides" do
      canvas = Canvas.new(grid_size: 10, snap_to_grid: false)
      assert canvas.grid_size == 10
      refute canvas.snap_to_grid
    end
  end

  describe "add_element/2" do
    test "assigns auto-incrementing ids" do
      {canvas, el1} = Canvas.add_element(bare_canvas(), %{x: 10.0, y: 20.0})
      {canvas, el2} = Canvas.add_element(canvas, %{})

      assert el1.id == "el-1"
      assert el2.id == "el-2"
      assert canvas.next_id == 3
      assert Map.keys(canvas.elements) |> Enum.sort() == ["el-1", "el-2"]
    end

    test "snaps position to the grid when snap_to_grid is on" do
      {_canvas, el} = Canvas.add_element(Canvas.new(), %{x: 33.0, y: 47.0})
      assert el.x == 40.0
      assert el.y == 40.0
    end

    test "keeps exact position when snap_to_grid is off" do
      {_canvas, el} = Canvas.add_element(bare_canvas(), %{x: 33.0, y: 47.0})
      assert el.x == 33.0
      assert el.y == 47.0
    end

    test "applies element type defaults" do
      {_canvas, el} = Canvas.add_element(bare_canvas(), %{type: :server})
      assert el.width == 120.0
      assert el.height == 100.0
      assert el.color == "#6366f1"
    end
  end

  describe "move_element/4" do
    test "moves by dx/dy" do
      {canvas, el} = Canvas.add_element(bare_canvas(), %{x: 100.0, y: 100.0})
      canvas = Canvas.move_element(canvas, el.id, 15.0, -5.0)

      moved = canvas.elements[el.id]
      assert moved.x == 115.0
      assert moved.y == 95.0
    end

    test "unknown id is a no-op" do
      {canvas, _el} = Canvas.add_element(bare_canvas(), %{})
      assert Canvas.move_element(canvas, "el-999", 10.0, 10.0) == canvas
    end
  end

  describe "resize_element/4" do
    test "resizes to the given dimensions" do
      {canvas, el} = Canvas.add_element(bare_canvas(), %{})
      canvas = Canvas.resize_element(canvas, el.id, 300.0, 90.0)

      resized = canvas.elements[el.id]
      assert resized.width == 300.0
      assert resized.height == 90.0
    end

    test "enforces the 20x20 minimum" do
      {canvas, el} = Canvas.add_element(bare_canvas(), %{})
      canvas = Canvas.resize_element(canvas, el.id, 5.0, 5.0)

      resized = canvas.elements[el.id]
      assert resized.width == 20.0
      assert resized.height == 20.0
    end

    test "unknown id is a no-op" do
      canvas = bare_canvas()
      assert Canvas.resize_element(canvas, "el-1", 50.0, 50.0) == canvas
    end
  end

  describe "update_element/3" do
    test "updates attributes" do
      {canvas, el} = Canvas.add_element(bare_canvas(), %{})
      canvas = Canvas.update_element(canvas, el.id, %{label: "web-1", z_index: 5})

      updated = canvas.elements[el.id]
      assert updated.label == "web-1"
      assert updated.z_index == 5
    end

    test "unknown id is a no-op" do
      canvas = bare_canvas()
      assert Canvas.update_element(canvas, "nope", %{label: "x"}) == canvas
    end
  end

  describe "remove_element/2" do
    test "removes the element and cascade-deletes its connections" do
      {canvas, a} = Canvas.add_element(bare_canvas(), %{})
      {canvas, b} = Canvas.add_element(canvas, %{})
      {canvas, c} = Canvas.add_element(canvas, %{})
      {canvas, _} = Canvas.add_connection(canvas, a.id, b.id)
      {canvas, kept} = Canvas.add_connection(canvas, b.id, c.id)
      {canvas, _} = Canvas.add_connection(canvas, c.id, a.id)

      canvas = Canvas.remove_element(canvas, a.id)

      refute Map.has_key?(canvas.elements, a.id)
      assert Map.keys(canvas.connections) == [kept.id]
    end
  end

  describe "duplicate_elements/3" do
    test "clones templates with fresh ids, offset, and status reset" do
      {canvas, el} =
        Canvas.add_element(bare_canvas(), %{x: 10.0, y: 10.0, label: "orig", type: :service})

      canvas = Canvas.set_element_status(canvas, el.id, :error)
      template = canvas.elements[el.id]

      {canvas, new_ids} = Canvas.duplicate_elements(canvas, [template], 20)

      assert new_ids == ["el-2"]
      clone = canvas.elements["el-2"]
      assert clone.x == 30.0
      assert clone.y == 30.0
      assert clone.label == "orig"
      assert clone.type == :service
      assert clone.status == :unknown
      assert map_size(canvas.elements) == 2
    end
  end

  describe "move_elements/4 and remove_elements/2" do
    test "moves multiple elements, skipping unknown ids" do
      {canvas, a} = Canvas.add_element(bare_canvas(), %{x: 0.0, y: 0.0})
      {canvas, b} = Canvas.add_element(canvas, %{x: 50.0, y: 50.0})

      canvas = Canvas.move_elements(canvas, [a.id, b.id, "el-999"], 5.0, 5.0)

      assert canvas.elements[a.id].x == 5.0
      assert canvas.elements[b.id].y == 55.0
    end

    test "removes multiple elements" do
      {canvas, a} = Canvas.add_element(bare_canvas(), %{})
      {canvas, b} = Canvas.add_element(canvas, %{})
      {canvas, c} = Canvas.add_element(canvas, %{})

      canvas = Canvas.remove_elements(canvas, [a.id, c.id])

      assert Map.keys(canvas.elements) == [b.id]
    end
  end

  describe "set_element_status/3" do
    test "sets a valid status" do
      {canvas, el} = Canvas.add_element(bare_canvas(), %{})
      canvas = Canvas.set_element_status(canvas, el.id, :warning)
      assert canvas.elements[el.id].status == :warning
    end

    test "unknown id is a no-op" do
      canvas = bare_canvas()
      assert Canvas.set_element_status(canvas, "el-9", :ok) == canvas
    end

    test "rejects invalid status atoms" do
      {canvas, el} = Canvas.add_element(bare_canvas(), %{})
      # Opaque to the compiler's type inference on purpose
      bogus = String.to_atom("bogus")

      assert_raise FunctionClauseError, fn ->
        Canvas.set_element_status(canvas, el.id, bogus)
      end
    end
  end

  describe "connections" do
    test "add_connection assigns ids and validates both endpoints exist" do
      {canvas, a} = Canvas.add_element(bare_canvas(), %{})
      {canvas, b} = Canvas.add_element(canvas, %{})

      {canvas, conn} = Canvas.add_connection(canvas, a.id, b.id, %{label: "link"})

      assert conn.id == "conn-1"
      assert conn.source_id == a.id
      assert conn.target_id == b.id
      assert conn.label == "link"
      assert canvas.next_conn_id == 2
    end

    test "add_connection with a missing endpoint returns nil and leaves canvas unchanged" do
      {canvas, a} = Canvas.add_element(bare_canvas(), %{})

      {canvas2, conn} = Canvas.add_connection(canvas, a.id, "el-999")

      assert conn == nil
      assert canvas2 == canvas
    end

    test "remove_connection and update_connection" do
      {canvas, a} = Canvas.add_element(bare_canvas(), %{})
      {canvas, b} = Canvas.add_element(canvas, %{})
      {canvas, conn} = Canvas.add_connection(canvas, a.id, b.id)

      updated = Canvas.update_connection(canvas, conn.id, %{style: :dashed})
      assert updated.connections[conn.id].style == :dashed

      removed = Canvas.remove_connection(updated, conn.id)
      assert removed.connections == %{}
    end

    test "update_connection with unknown id is a no-op" do
      canvas = bare_canvas()
      assert Canvas.update_connection(canvas, "conn-9", %{label: "x"}) == canvas
    end

    test "connections_for_element returns connections touching the element" do
      {canvas, a} = Canvas.add_element(bare_canvas(), %{})
      {canvas, b} = Canvas.add_element(canvas, %{})
      {canvas, c} = Canvas.add_element(canvas, %{})
      {canvas, ab} = Canvas.add_connection(canvas, a.id, b.id)
      {canvas, bc} = Canvas.add_connection(canvas, b.id, c.id)

      ids = Canvas.connections_for_element(canvas, b.id) |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == [bc.id, ab.id] |> Enum.sort()

      assert Canvas.connections_for_element(canvas, "el-999") == []
    end
  end

  describe "view" do
    test "pan/3 shifts the view box" do
      canvas = Canvas.pan(bare_canvas(), 100.0, -50.0)
      assert canvas.view_box.min_x == 100.0
      assert canvas.view_box.min_y == -50.0
    end

    test "zoom/4 scales the view box" do
      canvas = Canvas.zoom(bare_canvas(), 600.0, 400.0, 0.5)
      assert canvas.view_box.width == 600.0
      assert canvas.view_box.height == 400.0
    end
  end
end
