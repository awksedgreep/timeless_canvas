defmodule TimelessCanvas.DataSource.RandomTest do
  use ExUnit.Case, async: true

  alias TimelessCanvas.DataSource.Random

  describe "list_hosts/2" do
    test "returns a deterministic host list" do
      hosts = Random.list_hosts(%{}, [])

      assert hosts == Random.list_hosts(%{}, [])
      assert "web-01" in hosts
      assert "db-01" in hosts
    end

    test "applies a case-insensitive substring filter" do
      hosts = Random.list_hosts(%{}, filter: "WEB")

      assert hosts != []
      assert Enum.all?(hosts, &String.contains?(&1, "web"))
    end

    test "applies filter first, then limit" do
      assert [host] = Random.list_hosts(%{}, filter: "db", limit: 1)
      assert String.contains?(host, "db")

      assert length(Random.list_hosts(%{}, limit: 3)) == 3
    end
  end

  describe "list_label_values/3" do
    test "returns deterministic values per label key" do
      assert "eth0" in Random.list_label_values(%{}, "ifname", [])
      assert Random.list_label_values(%{}, "unknown_label", []) == []
    end

    test "applies filter and limit" do
      assert Random.list_label_values(%{}, "ifname", filter: "eth") == ["eth0", "eth1"]
      assert Random.list_label_values(%{}, "ifname", filter: "eth", limit: 1) == ["eth0"]
    end
  end

  describe "list_series_for_host/3" do
    test "returns {metric, labels} tuples tagged with the host" do
      series = Random.list_series_for_host(%{}, "web-01", [])

      assert series != []
      assert Enum.all?(series, fn {name, labels} -> is_binary(name) and is_map(labels) end)
      assert Enum.all?(series, fn {_name, labels} -> labels["host"] == "web-01" end)
    end

    test "filter matches against the metric name, limit bounds the result" do
      series = Random.list_series_for_host(%{}, "web-01", filter: "network")
      assert Enum.map(series, &elem(&1, 0)) == ["network_rx_bytes", "network_tx_bytes"]

      assert [{"network_rx_bytes", _}] =
               Random.list_series_for_host(%{}, "web-01", filter: "network", limit: 1)
    end
  end
end
