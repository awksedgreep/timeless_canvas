defmodule TimelessCanvas.DataQueriesTest do
  use ExUnit.Case, async: false

  alias TimelessCanvas.Canvas.Element
  alias TimelessCanvas.DataQueries
  alias TimelessCanvas.DataSource.Manager
  alias TimelessCanvas.Test.{FakeDataSource, FakeStreamBackend}

  @manager_table :timeless_canvas_data_source

  setup do
    previous_streams = Application.get_env(:timeless_canvas, :stream_backends)
    snapshot = {:ets.lookup(@manager_table, :source), :ets.lookup(@manager_table, :elements)}
    FakeDataSource.reset()
    FakeStreamBackend.reset()

    Application.put_env(:timeless_canvas, :stream_backends,
      log: FakeStreamBackend,
      trace: FakeStreamBackend
    )

    on_exit(fn ->
      FakeDataSource.reset()
      FakeStreamBackend.reset()
      restore_env(:stream_backends, previous_streams)
      {source, elements} = snapshot
      :ets.insert(@manager_table, source ++ elements)
    end)

    :ok
  end

  test "entry ids are stable, content-derived, and wider than phash2" do
    entry = %{message: "hello", id: "old"}
    first = DataQueries.put_entry_id(entry)
    second = DataQueries.put_entry_id(%{"id" => "different", message: "hello"})

    assert first.id == second.id
    assert is_binary(first.id)
    assert byte_size(first.id) >= 16
  end

  test "stream option builders allowlist enums and tolerate nil metadata" do
    assert DataQueries.build_log_opts(nil) == []
    assert DataQueries.build_log_opts(%{"level" => "error"})[:level] == :error
    refute Keyword.has_key?(DataQueries.build_log_opts(%{"level" => "not-a-level"}), :level)

    assert DataQueries.build_trace_opts(%{"kind" => "server"})[:kind] == :server
    refute Keyword.has_key?(DataQueries.build_trace_opts(%{"kind" => "Elixir.System"}), :kind)
  end

  test "historical stream maps accept atom, string, and missing backend keys" do
    FakeStreamBackend.set_query_result(
      {:ok,
       %{
         entries: [
           %{"timestamp" => 10, "level" => "info", "message" => "string keys"},
           %{timestamp: 11, message: "missing optional fields"}
         ]
       }}
    )

    log = Element.new(%{id: "log", type: :log_stream, meta: nil})
    result = DataQueries.query_stream_data(%{"log" => log}, DateTime.utc_now(), 60)
    assert Enum.map(result["log"], & &1.message) == ["string keys", "missing optional fields"]
    assert Enum.all?(result["log"], &is_binary(&1.id))
  end

  test "downsampling is linear, bounded, and keeps both endpoints" do
    canvas_id = System.unique_integer([:positive])
    graph = Element.new(%{id: "graph", type: :graph, meta: %{"metric_name" => "cpu"}})
    Manager.register_elements(canvas_id, [graph])
    on_exit(fn -> Manager.unregister_element(canvas_id, graph.id) end)

    FakeDataSource.put(:metric_range, {:ok, Enum.map(100..1//-1, &{&1, &1 * 1.0})})
    result = DataQueries.query_graph_data(canvas_id, %{graph.id => graph}, DateTime.utc_now(), 60)

    assert length(result[graph.id]) == 60
    assert hd(result[graph.id]) == {1, 1.0}
    assert List.last(result[graph.id]) == {100, 100.0}
  end

  test "a crashed element query becomes an explicit error" do
    canvas_id = System.unique_integer([:positive])
    graph = Element.new(%{id: "graph-error", type: :graph, meta: nil})
    Manager.register_elements(canvas_id, [graph])
    on_exit(fn -> Manager.unregister_element(canvas_id, graph.id) end)
    FakeDataSource.put(:metric_range, fn _element -> raise "backend down" end)

    assert DataQueries.query_graph_data(canvas_id, %{graph.id => graph}, DateTime.utc_now(), 60) ==
             %{
               graph.id => :error
             }
  end

  describe "cross-series option builders" do
    test "a graph asks for an aggregate only when a known one is set" do
      assert DataQueries.build_range_opts(nil) == []
      assert DataQueries.build_range_opts(%{}) == []
      assert DataQueries.build_range_opts(%{"aggregate" => ""}) == []
      assert DataQueries.build_range_opts(%{"aggregate" => "sum"}) == [aggregate: :sum]
      assert DataQueries.build_range_opts(%{"aggregate" => "Elixir.System"}) == []
    end

    test "top_n options are complete but for the window, which is the backend's" do
      assert Enum.sort(DataQueries.build_top_opts(nil)) ==
               [aggregate: :sum, group_by: [], limit: 10, order: :desc]
    end

    test "a window is passed only when the element sets one" do
      for bad <- ["", nil, "0", "-30", "soon", "30s"] do
        refute Keyword.has_key?(DataQueries.build_top_opts(%{"window" => bad}), :window)
        refute Keyword.has_key?(DataQueries.build_range_opts(%{"window" => bad}), :window)
      end

      assert DataQueries.build_top_opts(%{"window" => "30"})[:window] == 30
      assert DataQueries.build_range_opts(%{"window" => "30"}) == [window: 30]

      assert Enum.sort(DataQueries.build_range_opts(%{"window" => "30", "aggregate" => "sum"})) ==
               [aggregate: :sum, window: 30]
    end

    test "top_n options are parsed, bounded, and allowlisted" do
      opts =
        DataQueries.build_top_opts(%{
          "group_by" => " comm ,user,, comm",
          "limit" => "25",
          "order" => "asc",
          "aggregate" => "max",
          "window" => "60"
        })

      assert opts[:group_by] == ["comm", "user"]
      assert opts[:limit] == 25
      assert opts[:order] == :asc
      assert opts[:aggregate] == :max
      assert opts[:window] == 60

      for bad <- ["0", "-5", "ten", "5x", "", nil] do
        assert DataQueries.build_top_opts(%{"limit" => bad})[:limit] == 10
      end

      assert DataQueries.build_top_opts(%{"limit" => "500"})[:limit] == 50
      assert DataQueries.build_top_opts(%{"window" => "999999999"})[:window] == 86_400
      assert DataQueries.build_top_opts(%{"order" => "sideways"})[:order] == :desc
      assert DataQueries.build_top_opts(%{"aggregate" => "median"})[:aggregate] == :sum
    end
  end

  describe "query_top_data/3" do
    defp register_top(meta) do
      canvas_id = System.unique_integer([:positive])
      top = Element.new(%{id: "top", type: :top_n, meta: meta})
      Manager.register_elements(canvas_id, [top])
      on_exit(fn -> Manager.unregister_element(canvas_id, top.id) end)
      {canvas_id, %{top.id => top}}
    end

    test "returns the rows stamped with the query time" do
      {canvas_id, elements} = register_top(%{"metric_name" => "proc_cpu"})
      rows = [%{labels: %{"comm" => "a"}, value: 2}, %{labels: %{"comm" => "b"}, value: 1.5}]
      FakeDataSource.put(:top_series, {:ok, rows})
      time = ~U[2026-09-29 12:00:00Z]

      assert DataQueries.query_top_data(canvas_id, elements, time) ==
               %{"top" => {DateTime.to_unix(time, :millisecond), rows}}
    end

    test "drops malformed rows and never returns more than the limit" do
      {canvas_id, elements} = register_top(%{"metric_name" => "proc_cpu", "limit" => "2"})

      FakeDataSource.put(
        :top_series,
        {:ok,
         [
           %{labels: %{"comm" => "a"}, value: 3.0},
           %{labels: %{"comm" => "nan"}, value: "3"},
           %{labels: nil, value: 1.0},
           :garbage,
           %{labels: %{"comm" => "b"}, value: 2.0, extra: :ignored},
           %{labels: %{"comm" => "c"}, value: 1.0}
         ]}
      )

      assert %{"top" => {_ts, rows}} =
               DataQueries.query_top_data(canvas_id, elements, DateTime.utc_now())

      assert rows == [
               %{labels: %{"comm" => "a"}, value: 3.0},
               %{labels: %{"comm" => "b"}, value: 2.0}
             ]
    end

    test "a backend error, a bad reply, and a crash are all explicit errors" do
      {canvas_id, elements} = register_top(%{"metric_name" => "proc_cpu"})

      for reply <- [{:error, :limit}, :nonsense, {:ok, :not_a_list}] do
        FakeDataSource.put(:top_series, reply)

        assert DataQueries.query_top_data(canvas_id, elements, DateTime.utc_now()) ==
                 %{"top" => :error}
      end

      FakeDataSource.put(:top_series, fn _element, _opts -> raise "backend down" end)

      assert DataQueries.query_top_data(canvas_id, elements, DateTime.utc_now()) ==
               %{"top" => :error}
    end

    test "an element without a metric is not queried" do
      FakeDataSource.put(:top_series, fn _element, _opts -> flunk("queried without a metric") end)

      for meta <- [%{}, %{"metric_name" => ""}, nil] do
        {canvas_id, elements} = register_top(meta)
        assert DataQueries.query_top_data(canvas_id, elements, DateTime.utc_now()) == %{}
      end
    end

    test "a backend that cannot rank yields nothing rather than an error" do
      {canvas_id, elements} = register_top(%{"metric_name" => "proc_cpu"})
      :ets.insert(@manager_table, {:source, TimelessCanvas.DataSource.Stub, %{}})

      assert DataQueries.query_top_data(canvas_id, elements, DateTime.utc_now()) == %{}
    end

    test "query_value_data merges text and ranked values" do
      canvas_id = System.unique_integer([:positive])
      top = Element.new(%{id: "top", type: :top_n, meta: %{"metric_name" => "proc_cpu"}})
      text = Element.new(%{id: "text", type: :text_series, meta: %{"metric_name" => "fan"}})
      Manager.register_elements(canvas_id, [top, text])

      on_exit(fn ->
        Manager.unregister_element(canvas_id, top.id)
        Manager.unregister_element(canvas_id, text.id)
      end)

      rows = [%{labels: %{}, value: 1.0}]
      FakeDataSource.put(:top_series, {:ok, rows})
      FakeDataSource.put(:text_metric_at, {:ok, "42 rpm"})

      assert %{"top" => {ts, ^rows}, "text" => {ts, "42 rpm"}} =
               DataQueries.query_value_data(
                 canvas_id,
                 %{"top" => top, "text" => text},
                 DateTime.utc_now()
               )
    end
  end

  describe "query_metric_units/1" do
    test "a ranked counter carries no unit, a ranked gauge does" do
      top = Element.new(%{id: "top", type: :top_n, meta: %{"metric_name" => "m"}})
      graph = Element.new(%{id: "graph", type: :graph, meta: %{"metric_name" => "m"}})
      elements = %{"top" => top, "graph" => graph}

      FakeDataSource.put(:metric_metadata, {:ok, %{type: :counter, unit: "seconds"}})
      assert DataQueries.query_metric_units(elements) == %{"graph" => "seconds"}

      FakeDataSource.put(:metric_metadata, {:ok, %{type: :gauge, unit: "bytes"}})

      assert DataQueries.query_metric_units(elements) ==
               %{"graph" => "bytes", "top" => "bytes"}

      FakeDataSource.put(:metric_metadata, {:ok, %{"type" => "counter", "unit" => "seconds"}})
      assert DataQueries.query_metric_units(elements) == %{"graph" => "seconds"}

      FakeDataSource.put(:metric_metadata, {:ok, nil})
      assert DataQueries.query_metric_units(elements) == %{}
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:timeless_canvas, key)
  defp restore_env(key, value), do: Application.put_env(:timeless_canvas, key, value)
end
