defmodule TimelessCanvas.Test.FakeStreamBackend do
  @moduledoc """
  Minimal `TimelessCanvas.StreamSource` for tests.

  `subscribe/1` records the calling subscriber (the StreamManager's
  per-element task) plus its opts in a public ETS table, so tests can

    * count backend subscribe calls (`subscribe_count/0`) — the observable
      for StreamManager registration idempotency, and
    * push live entries into all subscriptions (`emit_log/1`,
      `emit_span/1`), driving the batched broadcast path end to end.

  Enable it per test with

      Application.put_env(:timeless_canvas, :stream_backends,
        log: FakeStreamBackend, trace: FakeStreamBackend)

  (restore the previous value in `on_exit`) and call `reset/0` in setup.
  """

  @behaviour TimelessCanvas.StreamSource

  @table :timeless_canvas_fake_stream_backend

  def ensure_table! do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:bag, :public, :named_table])
    end

    :ok
  end

  def reset do
    ensure_table!()
    :ets.delete_all_objects(@table)
    :ok
  end

  @impl true
  def subscribe(opts) do
    ensure_table!()
    :ets.insert(@table, {:subscriber, self(), opts})
    :ok
  end

  @impl true
  def query(_filters) do
    ensure_table!()

    case :ets.lookup(@table, :query_result) do
      [{:query_result, result} | _] -> result
      [] -> {:ok, %{entries: []}}
    end
  end

  @doc """
  Program the result of `query/1` — e.g. `{:error, :backend_down}` to
  exercise the stream error state. `reset/0` restores the default
  `{:ok, %{entries: []}}`.
  """
  def set_query_result(result) do
    ensure_table!()
    :ets.delete(@table, :query_result)
    :ets.insert(@table, {:query_result, result})
    :ok
  end

  @doc "Total number of subscribe/1 calls since the last reset."
  def subscribe_count do
    ensure_table!()
    length(:ets.match_object(@table, {:subscriber, :_, :_}))
  end

  @doc "Currently recorded `{subscriber_pid, opts}` pairs."
  def subscribers do
    ensure_table!()

    for {:subscriber, pid, opts} <- :ets.match_object(@table, {:subscriber, :_, :_}),
        do: {pid, opts}
  end

  @doc "Deliver a live log entry to every live subscription task."
  def emit_log(entry) do
    for {pid, _opts} <- subscribers(), Process.alive?(pid) do
      send(pid, {:timeless_logs, :entry, entry})
    end

    :ok
  end

  @doc "Deliver a live trace span to every live subscription task."
  def emit_span(span) do
    for {pid, _opts} <- subscribers(), Process.alive?(pid) do
      send(pid, {:timeless_traces, :span, span})
    end

    :ok
  end
end
