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

    test "unknown type safely falls back to rect" do
      el = Element.new(%{type: :mystery})
      assert el.type == :rect
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
      assert Element.defaults_for(:nope).type == :rect
    end

    test "normalizes string keys, string types, nil maps, and numeric strings" do
      el = Element.new(%{"type" => "graph", "x" => "12.5", "meta" => nil, "pins" => nil})

      assert el.type == :graph
      assert el.x == 12.5
      assert el.meta == %{}
      assert el.pins == %{}
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

    test "a top_n element carries its ranking options" do
      assert :top_n in Element.element_types()
      assert Element.new(%{type: "top_n"}).type == :top_n

      for field <- ~w(metric_name group_by limit order aggregate window) do
        assert field in Element.meta_fields(:top_n)
      end

      assert "aggregate" in Element.meta_fields(:graph)
    end

    test "pin dimensions" do
      assert Element.pin_dimensions() == [:host, :ifname]
    end
  end

  describe "query_labels/1" do
    test "every meta key outside the non-label list is a label filter" do
      meta = %{"host" => "web-01", "comm" => "beam.smp", "metric_name" => "cpu_usage"}

      assert Element.query_labels(meta) == %{"host" => "web-01", "comm" => "beam.smp"}
    end

    test "drops every non-label key" do
      meta = Map.new(Element.non_label_meta_keys(), &{&1, "set"})

      # series_label_key/value are both "set", so the pair is the only label
      assert Element.query_labels(meta) == %{"set" => "set"}
    end

    test "drops blank values" do
      assert Element.query_labels(%{"host" => "web-01", "ifname" => "", "env" => nil}) ==
               %{"host" => "web-01"}
    end

    test "applies the series label pair as a label" do
      meta = %{
        "host" => "web-01",
        "series_label_key" => "ifname",
        "series_label_value" => "eth0"
      }

      assert Element.query_labels(meta) == %{"host" => "web-01", "ifname" => "eth0"}
    end

    test "ignores an incomplete series label pair" do
      assert Element.query_labels(%{"series_label_key" => "ifname"}) == %{}

      assert Element.query_labels(%{"series_label_key" => "", "series_label_value" => "eth0"}) ==
               %{}
    end

    test "ranking and aggregate options never narrow the query" do
      meta = %{
        "host" => "web-01",
        "metric_name" => "proc_cpu",
        "group_by" => "comm",
        "limit" => "10",
        "order" => "desc",
        "aggregate" => "sum",
        "window" => "300"
      }

      assert Element.query_labels(meta) == %{"host" => "web-01"}
    end

    test "accepts an element, and tolerates meta that is not a map" do
      el = Element.new(%{type: :graph, meta: %{"host" => "web-01", "y_max" => "100"}})

      assert Element.query_labels(el) == %{"host" => "web-01"}
      assert Element.query_labels(%Element{meta: nil}) == %{}
      assert Element.query_labels(nil) == %{}
    end
  end

  describe "label_filter/1" do
    defp filter(text), do: Element.label_filter(%{"label_filter" => text})

    test "reads equality, inequality, and several values" do
      assert filter("kind!=slice") == [{"kind", :neq, ["slice"]}]
      assert filter("comm=postgres") == [{"comm", :eq, ["postgres"]}]

      assert filter("kind!=slice|manager, comm=postgres|pgbouncer") == [
               {"comm", :eq, ["postgres", "pgbouncer"]},
               {"kind", :neq, ["slice", "manager"]}
             ]
    end

    test "is forgiving of spacing, and of a term said twice" do
      assert filter("  kind != slice | manager ,kind!=slice") ==
               [{"kind", :neq, ["slice", "manager"]}]
    end

    test "keeps what a value is made of" do
      assert filter("proc=MyApp.Repo<0.512.0>") == [{"proc", :eq, ["MyApp.Repo<0.512.0>"]}]

      assert filter("group=fn in MyApp.Report.build/2") ==
               [{"group", :eq, ["fn in MyApp.Report.build/2"]}]

      assert filter("unit=mcotner/app=x.scope") == [{"unit", :eq, ["mcotner/app=x.scope"]}]
    end

    test "leaves out what does not parse, and narrows nothing when there is nothing" do
      assert filter("kind") == []
      assert filter("kind!=") == []
      assert filter("=slice") == []
      assert filter("kind!=|") == []
      assert filter("kind!=slice, nonsense, ,") == [{"kind", :neq, ["slice"]}]
      assert filter("") == []
      assert Element.label_filter(%{}) == []
      assert Element.label_filter(%{"label_filter" => nil}) == []
      assert Element.label_filter(nil) == []
    end

    test "is not itself a label" do
      assert Element.query_labels(%{"host" => "a", "label_filter" => "kind!=slice"}) ==
               %{"host" => "a"}
    end
  end

  describe "query_matchers/1" do
    test "is the labels and then the label filter" do
      element =
        Element.new(%{
          type: :top_n,
          meta: %{
            "host" => "web-01",
            "metric_name" => "unit_memory_bytes",
            "group_by" => "unit",
            "label_filter" => "kind!=slice|manager",
            "series_label_key" => "node",
            "series_label_value" => "app@web-01"
          }
        })

      assert Element.query_matchers(element) == [
               {"host", :eq, ["web-01"]},
               {"node", :eq, ["app@web-01"]},
               {"kind", :neq, ["slice", "manager"]}
             ]
    end

    test "is only the labels when there is no filter" do
      assert Element.query_matchers(%{"host" => "web-01", "limit" => "5"}) ==
               [{"host", :eq, ["web-01"]}]

      assert Element.query_matchers(nil) == []
    end
  end

  describe "matches?/2" do
    test "a series has to satisfy every matcher" do
      matchers = [{"host", :eq, ["a"]}, {"kind", :neq, ["slice", "manager"]}]

      assert Element.matches?(%{"host" => "a", "kind" => "service"}, matchers)
      refute Element.matches?(%{"host" => "a", "kind" => "slice"}, matchers)
      refute Element.matches?(%{"host" => "b", "kind" => "service"}, matchers)
      assert Element.matches?(%{"host" => "a", "kind" => "scope"}, [])
    end

    test "a label a series does not carry is unequal to everything" do
      assert Element.matches?(%{"host" => "a"}, [{"kind", :neq, ["slice"]}])
      refute Element.matches?(%{"host" => "a"}, [{"kind", :eq, ["service"]}])
    end
  end

  describe "move/3" do
    test "shifts by dx/dy" do
      el = Element.new(%{x: 10.0, y: 20.0}) |> Element.move(5.0, -30.0)
      assert el.x == 15.0
      assert el.y == -10.0
    end

    test "invalid deltas are ignored" do
      el = Element.new(%{x: 10.0, y: 20.0})
      assert Element.move(el, nil, "bad") == el
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
