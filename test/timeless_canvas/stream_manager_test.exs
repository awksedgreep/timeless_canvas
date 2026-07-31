defmodule TimelessCanvas.StreamManagerTest do
  # async: false — swaps the :stream_backends app env and shares the
  # FakeStreamBackend ETS table with the LiveView tests.
  use ExUnit.Case, async: false

  alias TimelessCanvas.StreamManager
  alias TimelessCanvas.Test.FakeStreamBackend

  setup do
    previous = Application.get_env(:timeless_canvas, :stream_backends)

    Application.put_env(:timeless_canvas, :stream_backends,
      log: FakeStreamBackend,
      trace: FakeStreamBackend
    )

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:timeless_canvas, :stream_backends)
        value -> Application.put_env(:timeless_canvas, :stream_backends, value)
      end
    end)

    FakeStreamBackend.reset()
    :ok
  end

  defp start_manager(opts \\ []) do
    name = :"stream_manager_test_#{System.unique_integer([:positive])}"
    pid = start_supervised!({StreamManager, Keyword.put(opts, :name, name)}, id: name)
    pid
  end

  defp log_entry(message) do
    %{
      timestamp: System.system_time(:millisecond),
      level: :info,
      message: message,
      metadata: %{}
    }
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("condition never became true")

      true ->
        Process.sleep(10)
        wait_until(fun, tries - 1)
    end
  end

  describe "idempotent registration" do
    test "re-registering with identical opts keeps the existing subscription" do
      manager = start_manager()

      assert :ok = StreamManager.register_log_stream(1, "el-a", [level: :info], manager)
      wait_until(fn -> FakeStreamBackend.subscribe_count() == 1 end)

      assert :ok = StreamManager.register_log_stream(1, "el-a", [level: :info], manager)
      # Synchronize with the manager (call above already did) and give a
      # would-be respawned task time to hit the backend.
      Process.sleep(50)
      assert FakeStreamBackend.subscribe_count() == 1
    end

    test "changed opts tear down and re-subscribe" do
      manager = start_manager()

      assert :ok = StreamManager.register_log_stream(1, "el-a", [level: :info], manager)
      wait_until(fn -> FakeStreamBackend.subscribe_count() == 1 end)

      assert :ok = StreamManager.register_log_stream(1, "el-a", [level: :error], manager)
      wait_until(fn -> FakeStreamBackend.subscribe_count() == 2 end)
    end
  end

  describe "batched per-canvas broadcasts" do
    test "entries within one window arrive as a single newest-first batch" do
      manager = start_manager(batch_ms: 50)
      Phoenix.PubSub.subscribe(TimelessCanvas.pubsub(), StreamManager.stream_topic(1))

      assert :ok = StreamManager.register_log_stream(1, "el-a", [], manager)
      wait_until(fn -> FakeStreamBackend.subscribe_count() == 1 end)

      FakeStreamBackend.emit_log(log_entry("m1"))
      FakeStreamBackend.emit_log(log_entry("m2"))
      FakeStreamBackend.emit_log(log_entry("m3"))

      assert_receive {:stream_entries, "el-a", entries}, 1_000
      assert ["m3", "m2", "m1"] = Enum.map(entries, & &1.message)
      assert Enum.all?(entries, &Map.has_key?(&1, :id))

      # Exactly one broadcast for the window — no per-entry messages.
      refute_receive {:stream_entries, _, _}, 200

      # The rolling buffer kept all three (newest first) for late joiners.
      assert ["m3", "m2", "m1"] =
               "el-a" |> StreamManager.get_buffer(manager) |> Enum.map(& &1.message)
    end

    test "a full window flushes immediately at the backpressure cap" do
      manager = start_manager(batch_ms: 60_000)
      Phoenix.PubSub.subscribe(TimelessCanvas.pubsub(), StreamManager.stream_topic(1))

      assert :ok = StreamManager.register_log_stream(1, "el-a", [], manager)
      wait_until(fn -> FakeStreamBackend.subscribe_count() == 1 end)

      for i <- 1..50, do: FakeStreamBackend.emit_log(log_entry("m#{i}"))

      # Despite the effectively infinite timer, the 50-entry cap forces a
      # flush without waiting.
      assert_receive {:stream_entries, "el-a", entries}, 1_000
      assert length(entries) == 50
      assert hd(entries).message == "m50"
    end

    test "broadcasts stay on their canvas's topic" do
      manager = start_manager(batch_ms: 20)
      Phoenix.PubSub.subscribe(TimelessCanvas.pubsub(), StreamManager.stream_topic(1))
      Phoenix.PubSub.subscribe(TimelessCanvas.pubsub(), StreamManager.stream_topic(2))

      assert :ok = StreamManager.register_log_stream(1, "el-a", [], manager)
      wait_until(fn -> FakeStreamBackend.subscribe_count() == 1 end)

      FakeStreamBackend.emit_log(log_entry("only-canvas-1"))

      # Delivered once, via canvas 1's topic (we are subscribed to both;
      # a global or canvas-2 broadcast would produce a second message).
      assert_receive {:stream_entries, "el-a", [%{message: "only-canvas-1"}]}, 1_000
      refute_receive {:stream_entries, _, _}, 200
    end

    test "registrant exit drops a canvas's subscriptions only when the last one dies" do
      manager = start_manager()
      parent = self()

      registrant = fn canvas_id, element_id ->
        pid =
          spawn(fn ->
            StreamManager.register_log_stream(canvas_id, element_id, [], manager)
            send(parent, {:registered, self()})

            receive do
              :stop -> :ok
            end
          end)

        assert_receive {:registered, ^pid}, 1_000
        pid
      end

      stop = fn pid ->
        ref = Process.monitor(pid)
        send(pid, :stop)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
        # Synchronize so the manager has processed its own DOWN.
        :sys.get_state(manager)
        Process.sleep(20)
      end

      subscriptions = fn -> :sys.get_state(manager).subscriptions end

      # Two viewers of canvas 1, one viewer of canvas 2.
      pid_a = registrant.(1, "el-mon")
      pid_b = registrant.(1, "el-mon")
      pid_c = registrant.(2, "el-other")

      wait_until(fn -> Map.has_key?(subscriptions.(), "el-mon") end)
      wait_until(fn -> Map.has_key?(subscriptions.(), "el-other") end)

      # First canvas-1 registrant exits: subscription survives.
      stop.(pid_a)
      assert Map.has_key?(subscriptions.(), "el-mon")

      # Last canvas-1 registrant exits: canvas 1's subscription is
      # dropped; canvas 2's is untouched.
      stop.(pid_b)
      wait_until(fn -> not Map.has_key?(subscriptions.(), "el-mon") end)
      assert Map.has_key?(subscriptions.(), "el-other")

      stop.(pid_c)
      wait_until(fn -> subscriptions.() == %{} end)
    end

    test "trace spans are batched as :stream_spans" do
      manager = start_manager(batch_ms: 20)
      Phoenix.PubSub.subscribe(TimelessCanvas.pubsub(), StreamManager.stream_topic(1))

      assert :ok = StreamManager.register_trace_stream(1, "el-t", [], manager)
      wait_until(fn -> FakeStreamBackend.subscribe_count() == 1 end)

      FakeStreamBackend.emit_span(%{
        timestamp: System.system_time(:millisecond),
        trace_id: "t1",
        span_id: "s1",
        name: "GET /",
        kind: :server,
        duration_ns: 1_000,
        status: :ok,
        status_message: nil,
        attributes: %{"service.name" => "web"},
        resource: %{}
      })

      assert_receive {:stream_spans, "el-t", [span]}, 1_000
      assert span.trace_id == "t1"
      assert span.service == "web"
      assert Map.has_key?(span, :id)
    end
  end
end
