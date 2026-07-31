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
end
