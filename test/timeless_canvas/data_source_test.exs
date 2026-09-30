defmodule TimelessCanvas.DataSourceTest do
  use ExUnit.Case, async: true

  alias TimelessCanvas.DataSource

  @series [
    {"proc_cpu_pct", %{"host" => "db-01", "proc" => "postgres[4548]", "comm" => "postgres"}},
    {"proc_cpu_pct", %{"host" => "db-01", "proc" => "sshd[812]", "comm" => "sshd"}},
    {"proc_rss_bytes", %{"host" => "db-01", "proc" => "postgres[4548]", "comm" => "postgres"}},
    {"unit_cpu_pct", %{"host" => "db-01", "unit" => "postgresql.service", "kind" => "service"}},
    {"sys_load1", %{"host" => "db-01"}},
    {"beam_proc_memory_bytes", %{"host" => "db-01", "proc" => "MyApp.Repo<0.512.0>"}}
  ]

  defp names(series), do: Enum.map(series, fn {name, labels} -> {name, labels["proc"]} end)

  describe "filter_series/2" do
    test "no filter is every series, in the order given" do
      assert DataSource.filter_series(@series, []) == @series
      assert DataSource.filter_series(@series, filter: nil) == @series
      assert DataSource.filter_series(@series, filter: "") == @series
      assert DataSource.filter_series(@series, filter: "   ") == @series
    end

    test "finds a series by its metric's name, as before" do
      assert @series |> DataSource.filter_series(filter: "proc_cpu") |> names() == [
               {"proc_cpu_pct", "postgres[4548]"},
               {"proc_cpu_pct", "sshd[812]"}
             ]
    end

    test "finds a series by a label's value" do
      found = DataSource.filter_series(@series, filter: "postgres")

      assert Enum.map(found, &elem(&1, 0)) ==
               ["proc_cpu_pct", "proc_rss_bytes", "unit_cpu_pct"]

      assert @series |> DataSource.filter_series(filter: "4548") |> length() == 2
      assert [{"beam_proc_memory_bytes", _}] = DataSource.filter_series(@series, filter: "0.512")
    end

    test "every word has to be found, in the name or in a label" do
      assert @series |> DataSource.filter_series(filter: "proc_cpu postgres") |> names() ==
               [{"proc_cpu_pct", "postgres[4548]"}]

      assert @series |> DataSource.filter_series(filter: "postgres  rss") |> names() ==
               [{"proc_rss_bytes", "postgres[4548]"}]

      assert DataSource.filter_series(@series, filter: "postgres sshd") == []
    end

    test "does not look at the names of labels" do
      # Every process series has a label named proc, and that finds nothing.
      assert DataSource.filter_series(@series, filter: "kind") == []
      assert DataSource.filter_series(@series, filter: "comm") == []
    end

    test "is in any case" do
      assert [{"beam_proc_memory_bytes", _}] =
               DataSource.filter_series(@series, filter: "myapp.REPO")

      assert @series |> DataSource.filter_series(filter: "POSTGRES") |> length() == 3
    end

    test "the filter is applied before the limit" do
      assert @series |> DataSource.filter_series(filter: "postgres", limit: 2) |> length() == 2
      assert [{"sys_load1", _}] = DataSource.filter_series(@series, filter: "sys", limit: 5)
      assert DataSource.filter_series(@series, limit: 1) == [hd(@series)]
    end

    test "a series with labels that are not text, or not a map, is still a series" do
      series = [{"m", %{"pid" => 4548, "up" => true}}, {"n", nil}, {"o", %{}}]

      assert [{"m", _}] = DataSource.filter_series(series, filter: "4548")
      assert [{"n", nil}] = DataSource.filter_series(series, filter: "n")
      assert DataSource.filter_series(series, []) == series
    end

    test "what is not a series is left out by a filter, and does not raise" do
      assert DataSource.filter_series([{"m", %{}}, :junk, "n"], filter: "m") == [{"m", %{}}]
    end
  end

  describe "apply_query_opts/3 is as it was" do
    test "a filter with a space in it is matched whole" do
      hosts = ["web 01", "web-01", "01 web"]

      assert DataSource.apply_query_opts(hosts, filter: "web 01") == ["web 01"]
      assert DataSource.apply_query_opts(hosts, filter: "WEB", limit: 2) == ["web 01", "web-01"]
    end
  end
end
