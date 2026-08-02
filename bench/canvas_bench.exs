# Canvas load benchmark (PLAN Phase 8).
#
# Run with:
#
#     MIX_ENV=test mix run bench/canvas_bench.exs
#
# Why this invocation: MIX_ENV=test compiles test/support (FakePersistence,
# FakeDataSource, the test endpoint/router) so the bench reuses the exact
# harness the unit suite runs against. The script replicates the
# test_helper.exs boot (application env + the same supervisor tree) with the
# non-E2E settings: no HTTP server and an effectively-infinite poll interval,
# so every measured operation is triggered explicitly — no background timer
# noise. Phoenix.LiveViewTest helpers demand an ExUnit test-process
# supervisor, so the script starts ExUnit (autorun: false) and registers the
# bench process with ExUnit.OnExitHandler; that is the one private-API touch
# and it is confined to this file. The alternative (an ExUnit file tagged
# :bench) was rejected because PLAN pins the `mix run bench/canvas_bench.exs`
# entry point and this turned out to work without a fight.
#
# The bench never runs under `mix test`: bench/ is outside the test paths and
# nothing in test/ references it.
#
# What is measured, per N in 25/100/300 elements (40% graphs, 40% servers,
# 20% log streams; graphs backed by a canned 60-point metric_range series):
#
#   mount_dead            dead render: HTTP GET through the endpoint
#   mount_live_async      live/2 (includes a dead render) + render_async
#                         (initial :initial_data async load merged)
#   tick_fanout_1v/_10v   manual CanvasPoller tick (send :poll) with all
#                         graph series changed, measured until 1 / 10
#                         subscribed viewer processes receive the broadcast
#   view_merge_push_0pct  {:canvas_data, ...} with an empty diff sent to one
#                         LiveView + synchronous render: the full
#                         push_graph_data payload rebuild with zero pushes
#   view_merge_push_100pct same, with fresh points for every graph element:
#                         merge + rebuild + push for 100% of graphs
#   scrub_round_trip      handle_event("timeline:change", %{"time" => ...})
#                         (statuses_at + per-graph metric_range refill)
#   undo / redo           handle_event("canvas:undo"/"canvas:redo") with a
#                         full 50-snapshot history at that N
#
# plus per-LiveView memory at each N with the full history:
# process_info(:memory) after GC, :erts_debug.size of the history assign
# (sharing-aware) and :erts_debug.flat_size (what copying it would cost).
#
# Stats: p50/p95 over 20 iterations after 3 discarded warmup iterations.
#
# Cross-contamination notes: FakePersistence/FakeDataSource are global. The
# bench never resets FakePersistence mid-run (ids would restart at 1 and
# collide with the previous scenario's poller/Manager registrations keyed by
# canvas id); each scenario seeds a fresh canvas record instead, and reprograms
# FakeDataSource for each phase. Stale StatusManager/StreamManager
# registrations from finished scenarios are inert because polling is disabled.

# --- Boot: mirror test/test_helper.exs (non-E2E branch) ---

Application.put_env(:timeless_canvas, :pubsub, TimelessCanvas.TestPubSub)
Application.put_env(:timeless_canvas, :persistence, TimelessCanvas.Test.FakePersistence)
Application.put_env(:timeless_canvas, :auth, TimelessCanvas.Auth.Noop)

Application.put_env(:timeless_canvas, :data_source,
  module: TimelessCanvas.Test.FakeDataSource,
  config: %{},
  # Background polling disabled; the bench sends :poll manually.
  poll_interval: 3_600_000
)

# Keep autosave timers out of the measured windows (undo/redo and the
# history-fill edits would otherwise interleave save attempts).
Application.put_env(:timeless_canvas, :autosave_ms, 3_600_000)
Application.put_env(:timeless_canvas, :autosave_retry_ms, 3_600_000)

Application.put_env(:timeless_canvas, TimelessCanvas.Test.Endpoint,
  secret_key_base: String.duplicate("timeless_canvas_secret_", 3),
  live_view: [signing_salt: "tc_lv_salt"],
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {127, 0, 0, 1}, port: 0],
  check_origin: false,
  render_errors: [formats: [html: TimelessCanvas.Test.ErrorHTML], layout: false],
  server: false
)

Logger.configure(level: :warning)
TimelessCanvas.Test.Icons.ensure_placeholders!()
TimelessCanvas.Test.FakeDataSource.ensure_table!()

{:ok, _} =
  Supervisor.start_link(
    [
      {Phoenix.PubSub, name: TimelessCanvas.TestPubSub},
      TimelessCanvas.Test.FakePersistence,
      TimelessCanvas.Supervisor,
      TimelessCanvas.Test.Endpoint
    ],
    strategy: :one_for_one,
    name: TimelessCanvas.TestSupervisor
  )

ExUnit.start(autorun: false)

defmodule CanvasBench do
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias TimelessCanvas.Canvas
  alias TimelessCanvas.Canvas.{Serializer, VariableResolver}
  alias TimelessCanvas.CanvasPoller
  alias TimelessCanvas.DataSource.Manager
  alias TimelessCanvas.Test.{FakeDataSource, FakePersistence}

  @endpoint TimelessCanvas.Test.Endpoint

  @ns [25, 100, 300]
  @warmup 3
  @iterations 20
  @series_points 60
  @async_timeout 30_000
  @user %{id: 1, username: "bench", email: "bench@example.com"}

  # --- Entry point ---

  def main do
    # LiveViewTest helpers require an ExUnit test-process supervisor.
    ExUnit.OnExitHandler.register(self())

    print_machine_header()

    {timings, memories} =
      Enum.reduce(@ns, {[], []}, fn n, {t_acc, m_acc} ->
        {timings, memory} = run_scenario(n)
        {t_acc ++ timings, m_acc ++ [memory]}
      end)

    print_timing_table(timings)
    print_memory_table(memories)
  end

  # --- Scenario (one per N) ---

  defp run_scenario(n) do
    IO.puts("\n== N=#{n} elements: measuring... ==")

    FakeDataSource.reset()
    program_static_data()

    canvas = build_canvas(n)
    data = canvas |> Serializer.encode() |> Jason.encode!() |> Jason.decode!()

    record =
      FakePersistence.seed_canvas(%{name: "Bench #{n}", user_id: @user.id, data: data})

    graph_ids = for {id, el} <- canvas.elements, el.type == :graph, do: id

    dead = bench_dead_mount(record)
    live_mount = bench_live_mount(record)

    # One persistent connected view for the event/diff/undo benchmarks.
    view = mount_view(record)

    scrub = bench_scrub(view)
    render_hook(view, "timeline:go_live", %{})

    diff0 = bench_merge_push(view, record.id, %{})
    diff100 = bench_merge_push(view, record.id, :all_changed, graph_ids)

    {undo, redo} = bench_undo_redo(view)
    memory = measure_memory(view, n)

    GenServer.stop(view.pid)
    flush_mailbox()

    {fanout1, fanout10} = bench_tick_fanout(record.id, canvas)

    timings =
      [
        {"mount_dead", n, dead},
        {"mount_live_async", n, live_mount},
        {"tick_fanout_1v", n, fanout1},
        {"tick_fanout_10v", n, fanout10},
        {"view_merge_push_0pct", n, diff0},
        {"view_merge_push_100pct", n, diff100},
        {"scrub_round_trip", n, scrub},
        {"undo", n, undo},
        {"redo", n, redo}
      ]

    {timings, memory}
  end

  # --- Canvas construction ---

  # Repeating [graph, server, graph, server, log_stream] gives exactly
  # 40% graphs / 40% servers / 20% log streams for the chosen Ns.
  defp build_canvas(n) do
    types = Stream.cycle([:graph, :server, :graph, :server, :log_stream])

    types
    |> Enum.take(n)
    |> Enum.with_index()
    |> Enum.reduce(Canvas.new(snap_to_grid: false), fn {type, i}, canvas ->
      attrs = %{
        type: type,
        x: rem(i, 20) * 160.0,
        y: div(i, 20) * 140.0,
        label: "#{type}-#{i}",
        meta: meta_for(type, i)
      }

      {canvas, _el} = Canvas.add_element(canvas, attrs)
      canvas
    end)
  end

  defp meta_for(:graph, i), do: %{"host" => "host-#{i}", "metric_name" => "cpu_usage"}
  defp meta_for(:server, i), do: %{"host" => "host-#{i}"}
  defp meta_for(:log_stream, i), do: %{"host" => "host-#{i}", "level" => "info"}

  defp program_static_data do
    FakeDataSource.put(:metric_range, {:ok, series(0)})
    FakeDataSource.put(:status, :ok)
    FakeDataSource.put(:status_at, :ok)
  end

  # A 60-point series ending now, whose values are offset by `salt` so
  # successive generations differ (forcing the poller/push diff paths).
  defp series(salt) do
    now_ms = System.system_time(:millisecond)

    for i <- (@series_points - 1)..0//-1 do
      {now_ms - i * 60_000, 40.0 + rem(i + salt, 25) * 1.0}
    end
  end

  # --- Benchmarks ---

  defp bench_dead_mount(record) do
    measure(fn _i ->
      conn = get(build_bench_conn(), "/canvas/#{record.id}")
      200 = conn.status
    end)
  end

  defp bench_live_mount(record) do
    measure(fn _i ->
      {:ok, view, _html} = live(build_bench_conn(), "/canvas/#{record.id}")
      render_async(view, @async_timeout)
      GenServer.stop(view.pid)
    end)
  end

  defp bench_scrub(view) do
    base_ms = System.system_time(:millisecond) - 1_800_000

    measure(fn i ->
      render_hook(view, "timeline:change", %{"time" => base_ms - i * 30_000})
    end)
  end

  defp bench_merge_push(view, canvas_id, diff, graph_ids \\ [])

  defp bench_merge_push(view, canvas_id, :all_changed, graph_ids) do
    measure(fn i ->
      graph_data = Map.new(graph_ids, fn id -> {id, series(i)} end)
      msg = {:canvas_data, canvas_id, %{graph_data: graph_data, text_data: %{}}}
      send(view.pid, msg)
      render(view)
    end)
  end

  defp bench_merge_push(view, canvas_id, empty_diff, _graph_ids) when is_map(empty_diff) do
    msg = {:canvas_data, canvas_id, %{graph_data: %{}, text_data: %{}}}

    measure(fn _i ->
      send(view.pid, msg)
      render(view)
    end)
  end

  # Fill the history to its 50-snapshot cap (51 non-coalescing moves), then
  # measure undo/redo as interleaved pairs so the history depth stays
  # constant across iterations.
  defp bench_undo_redo(view) do
    for _ <- 1..51 do
      render_hook(view, "element:move", %{"id" => "el-1", "dx" => 1, "dy" => 1})
    end

    pairs =
      for _ <- 1..(@warmup + @iterations) do
        t0 = System.monotonic_time(:microsecond)
        render_hook(view, "canvas:undo", %{})
        t1 = System.monotonic_time(:microsecond)
        render_hook(view, "canvas:redo", %{})
        t2 = System.monotonic_time(:microsecond)
        {t1 - t0, t2 - t1}
      end

    measured = Enum.drop(pairs, @warmup)
    {Enum.map(measured, &elem(&1, 0)), Enum.map(measured, &elem(&1, 1))}
  end

  defp measure_memory(view, n) do
    # Drain transient garbage from the mount + benchmark churn first.
    :erlang.garbage_collect(view.pid)
    {:memory, proc_bytes} = :erlang.process_info(view.pid, :memory)

    history = :sys.get_state(view.pid).socket.assigns.history
    words = :erlang.system_info(:wordsize)

    %{
      n: n,
      snapshots: length(history.past) + 1 + length(history.future),
      proc_bytes: proc_bytes,
      history_bytes: :erts_debug.size(history) * words,
      history_flat_bytes: :erts_debug.flat_size(history) * words
    }
  end

  # One deterministic poller tick: program metric_range to return fresh data
  # on every call (so every graph entry diffs as changed), subscribe plain
  # viewer processes to the data topic, send :poll manually, and time until
  # every viewer has seen the broadcast.
  defp bench_tick_fanout(canvas_id, canvas) do
    # The persistent LiveView's poller may still be lingering; restart it so
    # the bench process is its only lifecycle subscriber.
    case CanvasPoller.whereis(canvas_id) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    FakeDataSource.put(:metric_range, fn ->
      {:ok, series(System.unique_integer([:positive, :monotonic]))}
    end)

    {:ok, poller} =
      CanvasPoller.ensure_started(canvas_id, poll_interval: 3_600_000, linger: 3_600_000)

    bindings = VariableResolver.bindings(canvas.variables)
    resolved = VariableResolver.resolve_elements(canvas.elements, bindings)

    # The Manager unregistered the canvas's elements when the persistent
    # LiveView stopped (it monitors registrants); poller queries resolve
    # elements through the Manager, so re-register from the bench process.
    :ok = Manager.register_elements(canvas_id, Map.values(resolved))
    :ok = CanvasPoller.subscribe(canvas_id, resolved, span: 3600)

    fanout1 = fanout_run(poller, canvas_id, 1)
    fanout10 = fanout_run(poller, canvas_id, 10)

    GenServer.stop(poller)
    program_static_data()
    {fanout1, fanout10}
  end

  defp fanout_run(poller, canvas_id, viewer_count) do
    parent = self()
    topic = CanvasPoller.data_topic(canvas_id)

    viewers =
      for _ <- 1..viewer_count do
        spawn_link(fn ->
          Phoenix.PubSub.subscribe(TimelessCanvas.pubsub(), topic)
          send(parent, {:viewer_ready, self()})
          viewer_loop(parent)
        end)
      end

    Enum.each(viewers, fn pid ->
      receive do
        {:viewer_ready, ^pid} -> :ok
      after
        5_000 -> raise "viewer failed to subscribe"
      end
    end)

    times =
      measure(fn _i ->
        send(poller, :poll)
        await_ticks(viewer_count)
      end)

    Enum.each(viewers, fn pid ->
      Process.unlink(pid)
      Process.exit(pid, :kill)
    end)

    times
  end

  defp viewer_loop(parent) do
    receive do
      {:canvas_data, _canvas_id, _diffs} ->
        send(parent, :tick_seen)
        viewer_loop(parent)
    end
  end

  defp await_ticks(0), do: :ok

  defp await_ticks(remaining) do
    receive do
      :tick_seen -> await_ticks(remaining - 1)
    after
      10_000 -> raise "poller tick broadcast not received"
    end
  end

  # --- Harness helpers ---

  defp build_bench_conn do
    build_conn()
    |> Plug.Test.init_test_session(%{"current_user" => @user})
  end

  defp mount_view(record) do
    {:ok, view, _html} = live(build_bench_conn(), "/canvas/#{record.id}")
    render_async(view, @async_timeout)
    view
  end

  defp measure(fun) do
    Enum.each(1..@warmup, fn i -> fun.(i) end)

    for i <- 1..@iterations do
      t0 = System.monotonic_time(:microsecond)
      fun.(@warmup + i)
      System.monotonic_time(:microsecond) - t0
    end
  end

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      0 -> :ok
    end
  end

  # --- Reporting ---

  defp percentile(times, p) do
    sorted = Enum.sort(times)
    index = min(round(p / 100 * length(sorted) + 0.5) - 1, length(sorted) - 1)
    Enum.at(sorted, max(index, 0))
  end

  defp fmt_ms(us), do: :erlang.float_to_binary(us / 1000, decimals: 2)

  defp print_machine_header do
    cpu =
      case File.read("/proc/cpuinfo") do
        {:ok, contents} ->
          contents
          |> String.split("\n")
          |> Enum.find_value("unknown", fn line ->
            case String.split(line, ":", parts: 2) do
              ["model name" <> _, name] -> String.trim(name)
              _ -> nil
            end
          end)

        _ ->
          "unknown"
      end

    IO.puts("TimelessCanvas load benchmark")
    IO.puts("date: #{Date.utc_today()}")
    IO.puts("cpu: #{cpu} (#{System.schedulers_online()} schedulers online)")
    IO.puts("elixir: #{System.version()} / otp: #{System.otp_release()}")

    IO.puts(
      "iterations: #{@iterations} measured after #{@warmup} warmup; " <>
        "times are per-operation, in milliseconds"
    )
  end

  defp print_timing_table(timings) do
    IO.puts("\n#{String.pad_trailing("metric", 24)}#{header_cells()}")

    timings
    |> Enum.group_by(fn {label, _n, _t} -> label end)
    |> then(fn grouped ->
      # Preserve first-seen metric order.
      timings
      |> Enum.map(fn {label, _n, _t} -> label end)
      |> Enum.uniq()
      |> Enum.map(&{&1, Map.fetch!(grouped, &1)})
    end)
    |> Enum.each(fn {label, rows} ->
      cells =
        Enum.map_join(@ns, "", fn n ->
          {^label, ^n, times} = List.keyfind(rows, n, 1)

          "#{String.pad_leading(fmt_ms(percentile(times, 50)), 10)}" <>
            "#{String.pad_leading(fmt_ms(percentile(times, 95)), 10)}"
        end)

      IO.puts("#{String.pad_trailing(label, 24)}#{cells}")
    end)
  end

  defp header_cells do
    Enum.map_join(@ns, "", fn n ->
      "#{String.pad_leading("N=#{n} p50", 10)}#{String.pad_leading("p95", 10)}"
    end)
  end

  defp print_memory_table(memories) do
    IO.puts("\nPer-LiveView memory with full 50-snapshot history (KiB):")

    IO.puts(
      "#{String.pad_trailing("N", 8)}#{String.pad_leading("process", 12)}" <>
        "#{String.pad_leading("history", 12)}#{String.pad_leading("history_flat", 14)}"
    )

    Enum.each(memories, fn m ->
      IO.puts(
        "#{String.pad_trailing(to_string(m.n), 8)}" <>
          "#{String.pad_leading(fmt_kib(m.proc_bytes), 12)}" <>
          "#{String.pad_leading(fmt_kib(m.history_bytes), 12)}" <>
          "#{String.pad_leading(fmt_kib(m.history_flat_bytes), 14)}"
      )
    end)

    IO.puts(
      "(history = :erts_debug.size of the history assign, sharing-aware; " <>
        "history_flat = :erts_debug.flat_size, the cost if fully copied)"
    )
  end

  defp fmt_kib(bytes), do: :erlang.float_to_binary(bytes / 1024, decimals: 1)
end

CanvasBench.main()
