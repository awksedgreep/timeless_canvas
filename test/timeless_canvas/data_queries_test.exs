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

  defp restore_env(key, nil), do: Application.delete_env(:timeless_canvas, key)
  defp restore_env(key, value), do: Application.put_env(:timeless_canvas, key, value)
end
