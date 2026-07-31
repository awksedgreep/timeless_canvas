defmodule TimelessCanvas.CanvasPollerTest do
  # async: false — shares the Manager singleton's ETS table, the
  # FakeDataSource table, and the global CanvasRegistry/PollerSupervisor.
  use ExUnit.Case, async: false

  alias TimelessCanvas.Canvas.Element
  alias TimelessCanvas.CanvasPoller
  alias TimelessCanvas.DataSource.Manager
  alias TimelessCanvas.Test.FakeDataSource

  @manager_table :timeless_canvas_data_source
  @pubsub TimelessCanvas.TestPubSub

  setup do
    FakeDataSource.reset()
    snapshot = {:ets.lookup(@manager_table, :source), :ets.lookup(@manager_table, :elements)}
    canvas_id = System.unique_integer([:positive]) + 100_000

    on_exit(fn ->
      stop_poller(canvas_id)
      FakeDataSource.reset()
      {source_rows, element_rows} = snapshot
      :ets.delete(@manager_table, :source)
      :ets.delete(@manager_table, :elements)
      :ets.insert(@manager_table, source_rows ++ element_rows)
    end)

    {:ok, canvas_id: canvas_id}
  end

  defp stop_poller(canvas_id) do
    case CanvasPoller.whereis(canvas_id) do
      nil ->
        :ok

      pid ->
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
    end
  end

  defp graph_element(id) do
    Element.new(%{
      id: id,
      type: :graph,
      meta: %{"host" => "web-1", "metric_name" => "cpu_usage"}
    })
  end

  defp text_element(id) do
    Element.new(%{
      id: id,
      type: :text_series,
      meta: %{"host" => "web-1", "metric_name" => "fan_speed"}
    })
  end

  defp register_and_map(canvas_id, elements) do
    Manager.register_elements(canvas_id, elements)
    on_exit(fn -> Enum.each(elements, &Manager.unregister_element(&1.id)) end)
    Map.new(elements, &{&1.id, &1})
  end

  test "ensure_started is idempotent per canvas id", %{canvas_id: canvas_id} do
    assert {:ok, pid} = CanvasPoller.ensure_started(canvas_id, poll_interval: 3_600_000)
    assert {:ok, ^pid} = CanvasPoller.ensure_started(canvas_id, poll_interval: 3_600_000)
    assert CanvasPoller.whereis(canvas_id) == pid
  end

  test "broadcasts reach every topic subscriber and later ticks carry only diffs", %{
    canvas_id: canvas_id
  } do
    graph_id = "poller-graph-#{canvas_id}"
    text_id = "poller-text-#{canvas_id}"
    elements = register_and_map(canvas_id, [graph_element(graph_id), text_element(text_id)])

    # Graph data changes on every call; the text value never does.
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    FakeDataSource.put(:metric_range, fn ->
      n = Agent.get_and_update(counter, &{&1, &1 + 1})
      {:ok, [{1_000 + n, 1.0 * n}]}
    end)

    FakeDataSource.put(:text_metric_at, {:ok, "42 rpm"})

    parent = self()

    other =
      spawn_link(fn ->
        Phoenix.PubSub.subscribe(@pubsub, CanvasPoller.data_topic(canvas_id))
        :ok = CanvasPoller.subscribe(canvas_id, elements, poll_interval: 50, linger: 60_000)
        send(parent, :other_ready)

        receive do
          {:canvas_data, _, _} = msg -> send(parent, {:other_got, msg})
        end

        receive do
          :done -> :ok
        end
      end)

    Phoenix.PubSub.subscribe(@pubsub, CanvasPoller.data_topic(canvas_id))
    assert_receive :other_ready, 1_000
    :ok = CanvasPoller.subscribe(canvas_id, elements, poll_interval: 50, linger: 60_000)

    # First broadcast: everything is new, so both maps are populated.
    assert_receive {:canvas_data, ^canvas_id, %{graph_data: graph1, text_data: text1}}, 1_000
    assert [{_, _} | _] = graph1[graph_id]
    assert {_ts, "42 rpm"} = text1[text_id]

    # The second subscriber process receives the fan-out too.
    assert_receive {:other_got, {:canvas_data, ^canvas_id, _}}, 1_000

    # Second broadcast: graph points changed, text value did not — the
    # diff contains only the graph element.
    assert_receive {:canvas_data, ^canvas_id, %{graph_data: graph2, text_data: text2}}, 1_000
    assert Map.keys(graph2) == [graph_id]
    assert graph2[graph_id] != graph1[graph_id]
    assert text2 == %{}

    send(other, :done)
  end

  test "no broadcast when nothing changed", %{canvas_id: canvas_id} do
    graph_id = "poller-static-#{canvas_id}"
    elements = register_and_map(canvas_id, [graph_element(graph_id)])

    FakeDataSource.put(:metric_range, {:ok, [{1_000, 42.0}]})

    Phoenix.PubSub.subscribe(@pubsub, CanvasPoller.data_topic(canvas_id))
    :ok = CanvasPoller.subscribe(canvas_id, elements, poll_interval: 50, linger: 60_000)

    assert_receive {:canvas_data, ^canvas_id, %{graph_data: graph}}, 1_000
    assert graph[graph_id] == [{1_000, 42.0}]

    # Several ticks pass with identical data: silence.
    refute_receive {:canvas_data, _, _}, 300
  end

  test "poller stops after the last subscriber exits (post-linger)", %{canvas_id: canvas_id} do
    graph_id = "poller-linger-#{canvas_id}"
    elements = register_and_map(canvas_id, [graph_element(graph_id)])

    parent = self()

    subscriber =
      spawn(fn ->
        :ok = CanvasPoller.subscribe(canvas_id, elements, poll_interval: 3_600_000, linger: 50)
        send(parent, :subscribed)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :subscribed, 1_000
    poller = CanvasPoller.whereis(canvas_id)
    assert is_pid(poller)
    ref = Process.monitor(poller)

    # Poller survives while the subscriber lives.
    refute_receive {:DOWN, ^ref, :process, ^poller, _}, 150

    send(subscriber, :stop)
    assert_receive {:DOWN, ^ref, :process, ^poller, :normal}, 1_000
    assert CanvasPoller.whereis(canvas_id) in [nil, poller]
  end
end
