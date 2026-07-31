defmodule TimelessCanvas.Canvas.SerializerTest do
  use ExUnit.Case, async: true

  alias TimelessCanvas.Canvas
  alias TimelessCanvas.Canvas.{Serializer, ViewBox}

  defp sample_canvas do
    canvas = Canvas.new(snap_to_grid: false)
    {canvas, a} = Canvas.add_element(canvas, %{type: :server, x: 40.0, y: 60.0, label: "web-1"})
    {canvas, b} = Canvas.add_element(canvas, %{type: :database, x: 200.0, y: 60.0, label: "db-1"})
    {canvas, _conn} = Canvas.add_connection(canvas, a.id, b.id, %{label: "sql", style: :dashed})

    %{
      canvas
      | variables: %{"host" => %{"type" => "host", "current" => "web-1.example.com"}},
        view_box: %ViewBox{min_x: 10.0, min_y: 20.0, width: 600.0, height: 400.0}
    }
  end

  describe "encode/1" do
    test "produces a versioned, string-keyed map" do
      encoded = Serializer.encode(sample_canvas())

      assert encoded["version"] == 2

      assert encoded["view_box"] == %{
               "min_x" => 10.0,
               "min_y" => 20.0,
               "width" => 600.0,
               "height" => 400.0
             }

      assert encoded["elements"]["el-1"]["type"] == "server"
      assert encoded["connections"]["conn-1"]["style"] == "dashed"
      assert encoded["variables"]["host"]["current"] == "web-1.example.com"
    end

    test "the encoded map survives a JSON round trip" do
      encoded = Serializer.encode(sample_canvas())
      assert encoded == encoded |> Jason.encode!() |> Jason.decode!()
    end
  end

  describe "encode -> decode round trip" do
    test "preserves elements, connections, variables, and view_box" do
      original = sample_canvas()

      {:ok, decoded} =
        original
        |> Serializer.encode()
        |> Jason.encode!()
        |> Jason.decode!()
        |> Serializer.decode()

      assert decoded.view_box == original.view_box
      assert decoded.variables == original.variables
      assert decoded.next_id == original.next_id
      assert decoded.next_conn_id == original.next_conn_id
      assert decoded.grid_size == original.grid_size
      assert decoded.grid_visible == original.grid_visible
      assert decoded.snap_to_grid == original.snap_to_grid

      assert Map.keys(decoded.elements) |> Enum.sort() == ["el-1", "el-2"]
      el = decoded.elements["el-1"]
      assert el.type == :server
      assert el.x == 40.0
      assert el.y == 60.0
      assert el.label == "web-1"

      conn = decoded.connections["conn-1"]
      assert conn.source_id == "el-1"
      assert conn.target_id == "el-2"
      assert conn.label == "sql"
      assert conn.style == :dashed
    end
  end

  describe "decode/1" do
    test "accepts versions 1 and 2 with defaults for missing keys" do
      for version <- [1, 2] do
        assert {:ok, canvas} = Serializer.decode(%{"version" => version})
        assert canvas.elements == %{}
        assert canvas.connections == %{}
        assert canvas.variables == %{}
        assert canvas.view_box == %ViewBox{}
        assert canvas.grid_size == 20
      end
    end

    # create_canvas persists %{} as the initial blob, so explicitly-empty
    # data must decode as a brand-new canvas, never as corruption.
    test "empty map decodes to a fresh canvas" do
      assert {:ok, canvas} = Serializer.decode(%{})
      assert canvas == TimelessCanvas.Canvas.new()
    end

    test "nil decodes to a fresh canvas" do
      assert {:ok, canvas} = Serializer.decode(nil)
      assert canvas == TimelessCanvas.Canvas.new()
    end

    test "non-empty data without a version key returns an error" do
      assert {:error, _} = Serializer.decode(%{"elements" => %{}})
    end

    test "unsupported version returns an error" do
      assert {:error, "unsupported version"} = Serializer.decode(%{"version" => 99})
    end

    test "malformed elements payload returns an error" do
      assert {:error, _} = Serializer.decode(%{"version" => 2, "elements" => "garbage"})
    end

    test "unknown element type falls back to :rect" do
      data = %{
        "version" => 2,
        "elements" => %{"el-1" => %{"id" => "el-1", "type" => "definitely_not_an_atom_xyz"}}
      }

      assert {:ok, canvas} = Serializer.decode(data)
      assert canvas.elements["el-1"].type == :rect
    end

    test "element status always decodes to :unknown" do
      data = %{
        "version" => 2,
        "elements" => %{"el-1" => %{"id" => "el-1", "status" => "error"}}
      }

      assert {:ok, canvas} = Serializer.decode(data)
      assert canvas.elements["el-1"].status == :unknown
    end

    test "migrates legacy meta host/ifname values into pins" do
      data = %{
        "version" => 1,
        "elements" => %{
          "el-1" => %{"id" => "el-1", "meta" => %{"host" => "web-1", "ifname" => "$iface"}}
        }
      }

      assert {:ok, canvas} = Serializer.decode(data)
      pins = canvas.elements["el-1"].pins
      assert pins["host"] == %{"mode" => "literal", "value" => "web-1"}
      assert pins["ifname"] == %{"mode" => "variable", "value" => "$iface"}
    end

    test "missing meta values migrate to none-mode pins" do
      data = %{"version" => 2, "elements" => %{"el-1" => %{"id" => "el-1"}}}

      assert {:ok, canvas} = Serializer.decode(data)
      pins = canvas.elements["el-1"].pins
      assert pins["host"] == %{"mode" => "none", "value" => ""}
      assert pins["ifname"] == %{"mode" => "none", "value" => ""}
    end

    test "existing pins are not overwritten by migration" do
      pin = %{"mode" => "literal", "value" => "pinned-host"}

      data = %{
        "version" => 2,
        "elements" => %{
          "el-1" => %{"id" => "el-1", "meta" => %{"host" => "other"}, "pins" => %{"host" => pin}}
        }
      }

      assert {:ok, canvas} = Serializer.decode(data)
      assert canvas.elements["el-1"].pins["host"] == pin
    end
  end
end
