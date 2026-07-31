defmodule TimelessCanvas.DataSource.ManagerTest do
  # async: false — exercises the shared Manager singleton and its ETS table.
  use ExUnit.Case, async: false

  alias TimelessCanvas.Canvas.Element
  alias TimelessCanvas.DataSource.Manager
  alias TimelessCanvas.Test.FakeDataSource

  @table :timeless_canvas_data_source

  defmodule OldArityDS do
    @moduledoc "Backend exporting only the pre-opts arities (back-compat shim test)."
    def list_hosts(_state), do: ["alpha", "beta", "ALPHA-2", "gamma"]

    def list_label_values(_state, _label_key), do: ["eth0", "eth1", "bond0"]

    def list_series_for_host(_state, host),
      do: [{"cpu_usage", %{"host" => host}}, {"mem_usage", %{"host" => host}}, {"cpu_io", %{}}]
  end

  defmodule PerElementDS do
    @moduledoc "Backend without batch statuses_at/3 — forces per-element fallback."
    def status_at(_state, _element, _time), do: :warning
  end

  defmodule NoOptionalDS do
    @moduledoc "Backend exporting none of the optional callbacks."
  end

  setup do
    FakeDataSource.reset()
    snapshot = snapshot_rows()

    on_exit(fn ->
      FakeDataSource.reset()
      restore_rows(snapshot)
    end)

    :ok
  end

  defp snapshot_rows do
    {:ets.lookup(@table, :source), :ets.lookup(@table, :elements)}
  end

  defp restore_rows({source_rows, element_rows}) do
    :ets.delete(@table, :source)
    :ets.delete(@table, :elements)
    :ets.insert(@table, source_rows ++ element_rows)
  end

  defp put_source(module, ds_state \\ %{}) do
    :ets.insert(@table, {:source, module, ds_state})
  end

  defp put_elements(elements) when is_map(elements) do
    :ets.insert(@table, {:elements, elements})
  end

  defp element(id, attrs \\ %{}) do
    Element.new(Map.merge(%{id: id, type: :server, meta: %{"host" => id}}, attrs))
  end

  defp sync_manager do
    # Flush pending casts (unregister_element) with a synchronous round trip.
    :sys.get_state(Manager)
  end

  describe "caller-side execution (the refactor regression test)" do
    test "queries answer while the Manager GenServer is suspended" do
      Manager.register_elements(1, [element("suspended-el")])
      FakeDataSource.put(:metric_range, {:ok, [{1_000, 42.0}]})
      FakeDataSource.put(:list_hosts, ["host-a", "host-b"])

      :ok = :sys.suspend(Manager)

      try do
        from = DateTime.add(DateTime.utc_now(), -60, :second)
        to = DateTime.utc_now()

        assert Manager.metric_range("suspended-el", "cpu_usage", from, to) ==
                 {:ok, [{1_000, 42.0}]}

        assert Manager.list_hosts() == ["host-a", "host-b"]
      after
        :ok = :sys.resume(Manager)
      end

      Manager.unregister_element("suspended-el")
      sync_manager()
    end
  end

  describe "filter/limit opts" do
    test "reach the data source for list_hosts, list_label_values, list_series_for_host" do
      FakeDataSource.put(:list_hosts, ["alpha", "beta", "ALPHA-2", "gamma"])
      FakeDataSource.put(:list_label_values, ["eth0", "eth1", "bond0"])

      FakeDataSource.put(:list_series_for_host, [
        {"cpu_usage", %{}},
        {"mem_usage", %{}},
        {"cpu_io", %{}}
      ])

      assert Manager.list_hosts(filter: "alpha") == ["alpha", "ALPHA-2"]
      assert Manager.list_hosts(limit: 2) == ["alpha", "beta"]
      assert Manager.list_hosts(filter: "a", limit: 3) == ["alpha", "beta", "ALPHA-2"]

      assert Manager.list_label_values("ifname", filter: "ETH") == ["eth0", "eth1"]
      assert Manager.list_label_values("ifname", limit: 1) == ["eth0"]

      assert Manager.list_series_for_host("h1", filter: "cpu") ==
               [{"cpu_usage", %{}}, {"cpu_io", %{}}]

      assert Manager.list_series_for_host("h1", filter: "cpu", limit: 1) ==
               [{"cpu_usage", %{}}]
    end

    test "old-arity backends still work: shim applies filter+limit in Elixir" do
      put_source(OldArityDS)

      assert Manager.list_hosts() == ["alpha", "beta", "ALPHA-2", "gamma"]
      assert Manager.list_hosts(filter: "alpha") == ["alpha", "ALPHA-2"]
      assert Manager.list_hosts(filter: "alpha", limit: 1) == ["alpha"]

      assert Manager.list_label_values("ifname", filter: "eth", limit: 1) == ["eth0"]

      assert Manager.list_series_for_host("h1", filter: "cpu") ==
               [{"cpu_usage", %{"host" => "h1"}}, {"cpu_io", %{}}]
    end
  end

  describe "element registration visibility" do
    test "register_elements makes elements visible to caller-side metric_range" do
      FakeDataSource.put(:metric_range, {:ok, [{2_000, 7.5}]})
      from = DateTime.add(DateTime.utc_now(), -60, :second)
      to = DateTime.utc_now()

      assert Manager.metric_range("reg-el", "cpu_usage", from, to) == {:ok, []}

      Manager.register_elements(1, [element("reg-el")])
      assert Manager.metric_range("reg-el", "cpu_usage", from, to) == {:ok, [{2_000, 7.5}]}

      Manager.unregister_element("reg-el")
      sync_manager()
      assert Manager.metric_range("reg-el", "cpu_usage", from, to) == {:ok, []}
    end
  end

  describe "statuses_at/1" do
    test "uses the batch statuses_at/3 callback when exported" do
      put_elements(%{"b1" => element("b1"), "b2" => element("b2")})
      # Per-element status_at would report :error; the batch map says :warning.
      FakeDataSource.put(:status_at, :error)
      FakeDataSource.put(:statuses_at, %{"b1" => :warning, "b2" => :ok})

      assert Manager.statuses_at(DateTime.utc_now()) == %{"b1" => :warning, "b2" => :ok}
    end

    test "falls back to per-element status_at/3 when batch is not exported" do
      put_source(PerElementDS)
      put_elements(%{"p1" => element("p1"), "p2" => element("p2")})

      assert Manager.statuses_at(DateTime.utc_now()) == %{"p1" => :warning, "p2" => :warning}
    end
  end

  describe "safe fallbacks" do
    test "when the ETS rows are missing, queries return benign defaults" do
      :ets.delete(@table, :source)
      :ets.delete(@table, :elements)

      now = DateTime.utc_now()
      from = DateTime.add(now, -60, :second)

      assert Manager.statuses_at(now) == %{}
      assert Manager.metric_at("x", "cpu", now) == :no_data
      assert Manager.metric_range("x", "cpu", from, now) == {:ok, []}
      assert Manager.time_range() == :empty
      assert Manager.data_density(from, now, 10) == []
      assert Manager.list_series_for_host("h") == []
      assert Manager.list_hosts() == []
      assert Manager.list_label_values("ifname") == []
      assert Manager.metric_metadata("cpu") == {:ok, nil}
      assert Manager.text_metric_at("x", "cpu", now) == :no_data
    end

    test "when the backend exports no optional callbacks, queries return benign defaults" do
      put_source(NoOptionalDS)

      now = DateTime.utc_now()
      from = DateTime.add(now, -60, :second)

      assert Manager.data_density(from, now, 10) == []
      assert Manager.list_series_for_host("h") == []
      assert Manager.list_hosts() == []
      assert Manager.list_label_values("ifname") == []
      assert Manager.metric_metadata("cpu") == {:ok, nil}
    end

    test "Stub backend yields safe defaults for discovery queries" do
      put_source(TimelessCanvas.DataSource.Stub)

      assert Manager.list_hosts() == []
      assert Manager.list_label_values("ifname") == []
      assert Manager.list_series_for_host("h") == []
      assert Manager.time_range() == :empty
    end

    test "text_metric_at requires the optional callback and a registered element" do
      now = DateTime.utc_now()

      # FakeDataSource exports text_metric_at/4 but the element is unknown.
      assert Manager.text_metric_at("missing-el", "cpu", now) == :no_data

      put_elements(%{"t1" => element("t1", %{type: :text_series})})
      FakeDataSource.put(:text_metric_at, {:ok, "42 rpm"})
      assert Manager.text_metric_at("t1", "cpu", now) == {:ok, "42 rpm"}

      # Backend without the callback falls back to :no_data.
      put_source(PerElementDS)
      assert Manager.text_metric_at("t1", "cpu", now) == :no_data
    end
  end
end
