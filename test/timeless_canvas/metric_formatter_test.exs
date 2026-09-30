defmodule TimelessCanvas.MetricFormatterTest do
  use ExUnit.Case, async: true

  alias TimelessCanvas.MetricFormatter

  describe "format/2 without a unit" do
    test "zero" do
      assert MetricFormatter.format(0, nil) == "0"
      assert MetricFormatter.format(0.0, nil) == "0"
    end

    test "small fractions get three decimals" do
      assert MetricFormatter.format(0.1234, nil) == "0.123"
    end

    test "values >= 1 get two decimals" do
      assert MetricFormatter.format(2.5, nil) == "2.5"
      assert MetricFormatter.format(1.005, nil) == "1.0"
    end

    test "values >= 100 are rounded to integers" do
      assert MetricFormatter.format(150.4, nil) == "150"
      assert MetricFormatter.format(9999, nil) == "9999"
    end

    test "thousands / millions / billions" do
      assert MetricFormatter.format(15_000, nil) == "15.0K"
      assert MetricFormatter.format(2_500_000, nil) == "2.5M"
      assert MetricFormatter.format(3_000_000_000, nil) == "3.0G"
    end

    test "negative values use the same magnitudes" do
      assert MetricFormatter.format(-2_500_000, nil) == "-2.5M"
    end

    test "non-numbers format as placeholder" do
      assert MetricFormatter.format("bogus", nil) == "---"
      assert MetricFormatter.format(nil, nil) == "---"
    end
  end

  describe "format/2 with byte units" do
    test "bytes across magnitudes" do
      assert MetricFormatter.format(512, "bytes") == "512 B"
      assert MetricFormatter.format(2048, "bytes") == "2.0 KB"
      assert MetricFormatter.format(5 * 1_048_576, "byte") == "5.0 MB"
      assert MetricFormatter.format(2 * 1_073_741_824, "bytes") == "2.0 GB"
      assert MetricFormatter.format(3 * 1_099_511_627_776, "bytes") == "3.0 TB"
    end

    test "kilobytes and megabytes are scaled to bytes first" do
      assert MetricFormatter.format(2, "kilobytes") == "2.0 KB"
      assert MetricFormatter.format(3, "megabytes") == "3.0 MB"
    end
  end

  describe "format/2 with duration units" do
    test "seconds" do
      assert MetricFormatter.format(7200, "seconds") == "2.0h"
      assert MetricFormatter.format(90, "seconds") == "1.5m"
      assert MetricFormatter.format(2.5, "seconds") == "2.5s"
      assert MetricFormatter.format(0.5, "second") == "500.0ms"
    end

    test "milliseconds" do
      assert MetricFormatter.format(120_000, "milliseconds") == "2.0m"
      assert MetricFormatter.format(1500, "milliseconds") == "1.5s"
      assert MetricFormatter.format(12, "millisecond") == "12.0ms"
      assert MetricFormatter.format(0.5, "milliseconds") == "500.0us"
    end

    test "microseconds" do
      assert MetricFormatter.format(2_000_000, "microseconds") == "2.0s"
      assert MetricFormatter.format(1500, "microseconds") == "1.5ms"
      assert MetricFormatter.format(12, "microsecond") == "12.0us"
    end
  end

  describe "format/2 with percentage units" do
    test "percent values are shown as-is with one decimal" do
      assert MetricFormatter.format(42.123, "percent") == "42.1%"
      assert MetricFormatter.format(7, "%") == "7.0%"
    end

    test "ratio values are scaled to percent" do
      assert MetricFormatter.format(0.256, "ratio") == "25.6%"
      assert MetricFormatter.format(1.0, "ratio") == "100.0%"
    end
  end

  test "unknown units fall back to plain number formatting" do
    assert MetricFormatter.format(15_000, "florps") == "15.0K"
    assert MetricFormatter.format(2.5, "florps") == "2.5"
  end

  test "non-numeric values are placeholders for every unit" do
    for value <- [nil, :error, "12"], unit <- ["bytes", "seconds", "percent", "ratio"] do
      assert MetricFormatter.format(value, unit) == "---"
    end
  end

  describe "unit_from_name/1" do
    test "reads the unit a metric is named for" do
      for {name, unit} <- [
            {"proc_rss_bytes", "bytes"},
            {"sys_cpu_busy_pct", "percent"},
            {"disk_used_percent", "percent"},
            {"sys_net_rx_bytes_per_sec", "bytes_per_second"},
            {"node_network_bytes_per_second", "bytes_per_second"},
            {"sys_forks_per_sec", "per_second"},
            {"beam_vm_reductions_per_sec", "per_second"},
            {"proc_cpu_seconds", "seconds"},
            {"sys_disk_await_ms", "milliseconds"},
            {"http_request_duration_milliseconds", "milliseconds"},
            {"sys_temp_celsius", "celsius"},
            {"sys_fan_rpm", "rpm"},
            {"sys_power_watts", "watts"},
            {"sys_cpu_mhz", "megahertz"},
            {"SYS_MEM_USED_BYTES", "bytes"}
          ] do
        assert MetricFormatter.unit_from_name(name) == unit, name
      end
    end

    test "the longest ending is the unit" do
      # Bytes a second are not bytes, and not a count a second.
      assert MetricFormatter.unit_from_name("x_bytes_per_sec") == "bytes_per_second"
      assert MetricFormatter.unit_from_name("x_per_sec") == "per_second"
      assert MetricFormatter.unit_from_name("x_milliseconds") == "milliseconds"
    end

    test "a name that ends in no unit has none" do
      for name <- [
            "sys_load1",
            "proc_threads",
            "cpu_usage",
            "bytes",
            "pct",
            "rss_bytes_total",
            "megabytes",
            "",
            nil,
            :atom,
            42
          ] do
        assert MetricFormatter.unit_from_name(name) == nil, inspect(name)
      end
    end

    test "a moment is not a length of time" do
      assert MetricFormatter.unit_from_name("process_start_time_seconds") == nil
      assert MetricFormatter.unit_from_name("last_scrape_timestamp_seconds") == nil
      assert MetricFormatter.unit_from_name("sys_uptime_seconds") == "seconds"
    end
  end

  describe "format/2 with the units a name can give" do
    test "rates" do
      assert MetricFormatter.format(1536, "bytes_per_second") == "1.5 KB/s"
      assert MetricFormatter.format(0, "bytes_per_second") == "0 B/s"
      assert MetricFormatter.format(12.5, "per_second") == "12.5/s"
      assert MetricFormatter.format(25_000, "per_second") == "25.0K/s"
    end

    test "the rest" do
      assert MetricFormatter.format(61.26, "celsius") == "61.3°C"
      assert MetricFormatter.format(1200, "rpm") == "1200 rpm"
      assert MetricFormatter.format(45.5, "watts") == "45.5 W"
      assert MetricFormatter.format(3400, "megahertz") == "3400 MHz"
    end

    test "every unit a name can give is one format/2 knows" do
      for name <- ~w(a_bytes a_pct a_percent a_bytes_per_sec a_bytes_per_second a_per_sec
                     a_per_second a_seconds a_ms a_milliseconds a_celsius a_rpm a_watts a_mhz) do
        unit = MetricFormatter.unit_from_name(name)
        assert is_binary(unit), name
        # A unit format/2 did not know would be written as a bare number.
        refute MetricFormatter.format(1536.0, unit) == MetricFormatter.format(1536.0, nil), name
      end
    end
  end
end
