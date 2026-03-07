defmodule TimelessCanvas.MetricFormatter do
  @moduledoc "Format metric values based on unit metadata."

  def format(value, nil), do: format_number(value)
  def format(value, unit) when is_binary(unit), do: format_with_unit(value, unit)

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
