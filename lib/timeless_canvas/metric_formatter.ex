defmodule TimelessCanvas.MetricFormatter do
  @moduledoc """
  Format metric values based on unit metadata, or on the unit a metric is
  named for where there is no metadata.
  """

  # Longest first: `_bytes_per_sec` is not `_per_sec`, nor `_bytes`.
  @suffix_units [
    {"_bytes_per_second", "bytes_per_second"},
    {"_bytes_per_sec", "bytes_per_second"},
    {"_milliseconds", "milliseconds"},
    {"_per_second", "per_second"},
    {"_per_sec", "per_second"},
    {"_percent", "percent"},
    {"_celsius", "celsius"},
    {"_seconds", "seconds"},
    {"_bytes", "bytes"},
    {"_watts", "watts"},
    {"_mhz", "megahertz"},
    {"_pct", "percent"},
    {"_rpm", "rpm"},
    {"_ms", "milliseconds"}
  ]

  # Seconds since 1970, and not a length of time.
  @moments ["_timestamp_seconds", "_time_seconds"]

  @doc """
  The unit a metric is named for, by the convention that a name ends in its
  unit: `proc_rss_bytes`, `sys_cpu_busy_pct`, `sys_net_rx_bytes_per_sec`.
  `nil` for a name that ends in none.

  A series written through a Prometheus import route has no metadata, and
  its name is all there is to say what it counts.
  """
  @spec unit_from_name(term()) :: String.t() | nil
  def unit_from_name(name) when is_binary(name) do
    name = String.downcase(name)

    if String.ends_with?(name, @moments) do
      nil
    else
      Enum.find_value(@suffix_units, fn {suffix, unit} ->
        if String.ends_with?(name, suffix), do: unit
      end)
    end
  end

  def unit_from_name(_name), do: nil

  def format(value, _unit) when not is_number(value), do: "---"
  def format(value, nil), do: format_number(value)
  def format(value, unit) when is_binary(unit), do: format_with_unit(value, unit)
  def format(value, _unit), do: format_number(value)

  defp format_with_unit(value, unit) when unit in ["byte", "bytes"] do
    format_bytes(value)
  end

  defp format_with_unit(value, unit) when unit in ["kilobyte", "kilobytes"] do
    format_bytes(value * 1024)
  end

  defp format_with_unit(value, unit) when unit in ["megabyte", "megabytes"] do
    format_bytes(value * 1024 * 1024)
  end

  defp format_with_unit(value, unit) when unit in ["second", "seconds"] do
    format_duration_s(value)
  end

  defp format_with_unit(value, unit) when unit in ["millisecond", "milliseconds"] do
    format_duration_ms(value)
  end

  defp format_with_unit(value, unit) when unit in ["microsecond", "microseconds"] do
    format_duration_us(value)
  end

  defp format_with_unit(value, unit) when unit in ["percent", "%"] do
    "#{Float.round(value / 1, 1)}%"
  end

  defp format_with_unit(value, "ratio") do
    "#{Float.round(value * 100, 1)}%"
  end

  defp format_with_unit(value, unit) when unit in ["bytes_per_second", "bytes/s"] do
    format_bytes(value) <> "/s"
  end

  defp format_with_unit(value, unit) when unit in ["per_second", "/s"] do
    format_number(value) <> "/s"
  end

  defp format_with_unit(value, "celsius"), do: "#{Float.round(value / 1, 1)}°C"
  defp format_with_unit(value, "rpm"), do: format_number(value) <> " rpm"
  defp format_with_unit(value, "watts"), do: format_number(value) <> " W"
  defp format_with_unit(value, "megahertz"), do: format_number(value) <> " MHz"

  defp format_with_unit(value, _unit), do: format_number(value)

  # Bytes -> human-readable
  defp format_bytes(b) when b >= 1_099_511_627_776,
    do: "#{Float.round(b / 1_099_511_627_776, 1)} TB"

  defp format_bytes(b) when b >= 1_073_741_824, do: "#{Float.round(b / 1_073_741_824, 1)} GB"
  defp format_bytes(b) when b >= 1_048_576, do: "#{Float.round(b / 1_048_576, 1)} MB"
  defp format_bytes(b) when b >= 1024, do: "#{Float.round(b / 1024, 1)} KB"
  defp format_bytes(b), do: "#{round(b)} B"

  # Duration formatters
  defp format_duration_s(s) when s >= 3600, do: "#{Float.round(s / 3600, 1)}h"
  defp format_duration_s(s) when s >= 60, do: "#{Float.round(s / 60, 1)}m"
  defp format_duration_s(s) when s >= 1, do: "#{Float.round(s / 1, 1)}s"
  defp format_duration_s(s), do: "#{Float.round(s * 1000, 1)}ms"

  defp format_duration_ms(ms) when ms >= 60_000, do: "#{Float.round(ms / 60_000, 1)}m"
  defp format_duration_ms(ms) when ms >= 1000, do: "#{Float.round(ms / 1000, 1)}s"
  defp format_duration_ms(ms) when ms >= 1, do: "#{Float.round(ms / 1, 1)}ms"
  defp format_duration_ms(ms), do: "#{Float.round(ms * 1000, 1)}us"

  defp format_duration_us(us) when us >= 1_000_000, do: "#{Float.round(us / 1_000_000, 1)}s"
  defp format_duration_us(us) when us >= 1000, do: "#{Float.round(us / 1000, 1)}ms"
  defp format_duration_us(us), do: "#{Float.round(us / 1, 1)}us"

  # Generic number formatting
  defp format_number(val) when is_float(val) or is_integer(val) do
    abs_val = abs(val)

    cond do
      abs_val >= 1_000_000_000 -> "#{Float.round(val / 1_000_000_000, 1)}G"
      abs_val >= 1_000_000 -> "#{Float.round(val / 1_000_000, 1)}M"
      abs_val >= 10_000 -> "#{Float.round(val / 1_000, 1)}K"
      abs_val >= 100 -> "#{round(val)}"
      abs_val >= 1 -> "#{Float.round(val / 1, 2)}"
      abs_val == 0 -> "0"
      true -> "#{Float.round(val / 1, 3)}"
    end
  end

  defp format_number(_), do: "---"
end
