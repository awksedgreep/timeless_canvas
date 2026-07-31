defmodule TimelessCanvas.Canvas.VariableResolverTest do
  use ExUnit.Case, async: true

  alias TimelessCanvas.Canvas.{Element, VariableResolver}

  describe "bindings/1" do
    test "maps variable names to their current values" do
      variables = %{
        "host" => %{"type" => "host", "current" => "web-1"},
        "ifname" => %{"type" => "label", "current" => "eth0"}
      }

      assert VariableResolver.bindings(variables) == %{"host" => "web-1", "ifname" => "eth0"}
    end

    test "missing current value defaults to empty string" do
      assert VariableResolver.bindings(%{"host" => %{"type" => "host"}}) == %{"host" => ""}
    end

    test "empty variables produce empty bindings" do
      assert VariableResolver.bindings(%{}) == %{}
    end
  end

  describe "resolve_element/2" do
    test "resolves $var references in meta values and label" do
      el = Element.new(%{label: "$host", meta: %{"host" => "$host", "port" => "5432"}})

      resolved = VariableResolver.resolve_element(el, %{"host" => "web-1"})

      assert resolved.label == "web-1"
      assert resolved.meta["host"] == "web-1"
      assert resolved.meta["port"] == "5432"
    end

    test "whole-value matching only: prefixed references are not substituted" do
      el = Element.new(%{label: "prefix-$host", meta: %{"host" => "prefix-$host"}})

      resolved = VariableResolver.resolve_element(el, %{"host" => "web-1"})

      assert resolved.label == "prefix-$host"
      assert resolved.meta["host"] == "prefix-$host"
    end

    test "unbound variables keep their $reference" do
      el = Element.new(%{label: "$missing", meta: %{"host" => "$missing"}})

      resolved = VariableResolver.resolve_element(el, %{})

      assert resolved.label == "$missing"
      assert resolved.meta["host"] == "$missing"
    end

    test "literal pin overrides meta value" do
      el =
        Element.new(%{
          meta: %{"host" => "from-meta"},
          pins: %{"host" => %{"mode" => "literal", "value" => "pinned"}}
        })

      resolved = VariableResolver.resolve_element(el, %{})
      assert resolved.meta["host"] == "pinned"
    end

    test "variable pin resolves through bindings" do
      el = Element.new(%{pins: %{"ifname" => %{"mode" => "variable", "value" => "$ifname"}}})

      resolved = VariableResolver.resolve_element(el, %{"ifname" => "eth0"})
      assert resolved.meta["ifname"] == "eth0"
    end

    test "variable pin without binding keeps the $reference" do
      el = Element.new(%{pins: %{"host" => %{"mode" => "variable", "value" => "$host"}}})

      resolved = VariableResolver.resolve_element(el, %{})
      assert resolved.meta["host"] == "$host"
    end

    test "none-mode pin leaves meta untouched" do
      el =
        Element.new(%{
          meta: %{"host" => "kept"},
          pins: %{"host" => %{"mode" => "none", "value" => "ignored"}}
        })

      resolved = VariableResolver.resolve_element(el, %{})
      assert resolved.meta["host"] == "kept"
    end

    test "empty literal pin value is ignored" do
      el =
        Element.new(%{
          meta: %{"host" => "kept"},
          pins: %{"host" => %{"mode" => "literal", "value" => ""}}
        })

      resolved = VariableResolver.resolve_element(el, %{})
      assert resolved.meta["host"] == "kept"
    end
  end

  describe "resolve_elements/2" do
    test "resolves every element in the map" do
      elements = %{
        "el-1" => Element.new(%{id: "el-1", label: "$host"}),
        "el-2" => Element.new(%{id: "el-2", label: "static"})
      }

      resolved = VariableResolver.resolve_elements(elements, %{"host" => "web-1"})

      assert resolved["el-1"].label == "web-1"
      assert resolved["el-2"].label == "static"
    end

    test "empty element map returns empty map" do
      assert VariableResolver.resolve_elements(%{}, %{"host" => "x"}) == %{}
    end
  end
end
