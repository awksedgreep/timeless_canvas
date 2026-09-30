defmodule TimelessCanvas.LocalTime do
  @moduledoc """
  The viewer's clock, for every time the server writes.

  The hooks write times in the browser's zone. The server has to write them
  in the same one, or a graph's tooltip and the axis under it disagree. So the
  browser says what its zone is, and how far from UTC it is at the moment, and
  the server formats by that.

  A zone's name is used where the host application has a time zone database
  (`config :elixir, :time_zone_database`), which gets a time on the other side
  of a change to or from summer time right. Without one, the distance from
  UTC at the moment the page was opened is used for every time.

  Until the browser has said, and wherever nothing asks, the clock is UTC.
  """

  @type t :: %{zone: String.t() | nil, offset: integer()}

  # No zone is further from UTC than 14 hours; 18 is what ISO 8601 allows.
  @max_offset 18 * 3600

  # The names a browser has for UTC itself. A viewer on one of them has the
  # clock the server started with, and nothing to be written again.
  @utc_names ~w(UTC Etc/UTC Etc/UCT Etc/Universal Etc/Zulu Etc/GMT GMT UCT Universal Zulu)

  @doc "UTC."
  @spec utc() :: t()
  def utc, do: %{zone: nil, offset: 0}

  @doc """
  The clock a browser reports, as `%{"zone" => name, "offset_minutes" => east}`.
  Anything that is not plainly a zone or an offset is left out, and what is
  left out is UTC.
  """
  @spec from_client(term()) :: t()
  def from_client(%{} = params) do
    case %{zone: zone(params["zone"]), offset: offset(params["offset_minutes"])} do
      %{zone: name, offset: 0} when name in @utc_names -> utc()
      clock -> clock
    end
  end

  def from_client(_params), do: utc()

  defp zone(name) when is_binary(name) and byte_size(name) in 1..64 do
    if name =~ ~r/\A[A-Za-z0-9_+\-]+(\/[A-Za-z0-9_+\-]+)*\z/, do: name
  end

  defp zone(_name), do: nil

  defp offset(minutes) when is_integer(minutes) and abs(minutes) * 60 <= @max_offset,
    do: minutes * 60

  defp offset(_minutes), do: 0

  @doc """
  A moment as the viewer's clock reads it. `:error` for a moment no clock has.
  """
  @spec shift(integer(), t()) :: {:ok, NaiveDateTime.t()} | :error
  def shift(unix_ms, tz) when is_integer(unix_ms) do
    # The sum is done on a time with no zone: adding to a DateTime asks the
    # time zone database about UTC, and a database need not know it.
    with {:ok, moment} <- DateTime.from_unix(unix_ms, :millisecond) do
      {:ok, moment |> DateTime.to_naive() |> NaiveDateTime.add(offset_at(moment, tz), :second)}
    else
      _ -> :error
    end
  end

  def shift(_unix_ms, _tz), do: :error

  @doc """
  A moment written by `Calendar.strftime/2`, or `fallback` for a moment no
  clock has.
  """
  @spec format(integer(), t(), String.t(), String.t()) :: String.t()
  def format(unix_ms, tz, format, fallback \\ "") do
    case shift(unix_ms, tz) do
      {:ok, local} -> Calendar.strftime(local, format)
      :error -> fallback
    end
  end

  @doc "The day it is on the viewer's clock."
  @spec today(t()) :: Date.t()
  def today(tz) do
    case shift(System.system_time(:millisecond), tz) do
      {:ok, local} -> NaiveDateTime.to_date(local)
      :error -> Date.utc_today()
    end
  end

  @doc """
  A timestamp in milliseconds, whatever it was in. Stores keep time in
  seconds, milliseconds, microseconds, or nanoseconds, and a timestamp of our
  own time is of a size that says which.
  """
  @spec to_ms(term()) :: {:ok, integer()} | :error
  def to_ms(%DateTime{} = moment), do: {:ok, DateTime.to_unix(moment, :millisecond)}
  def to_ms(ts) when is_integer(ts) and ts > 10_000_000_000_000_000, do: {:ok, div(ts, 1_000_000)}
  def to_ms(ts) when is_integer(ts) and ts > 10_000_000_000_000, do: {:ok, div(ts, 1_000)}
  def to_ms(ts) when is_integer(ts) and ts > 10_000_000_000, do: {:ok, ts}
  def to_ms(ts) when is_integer(ts) and ts > 0, do: {:ok, ts * 1_000}
  def to_ms(_ts), do: :error

  defp offset_at(_moment, %{zone: nil, offset: offset}), do: offset

  defp offset_at(moment, %{zone: zone, offset: offset}) do
    case DateTime.shift_zone(moment, zone) do
      {:ok, shifted} -> shifted.utc_offset + shifted.std_offset
      {:error, _reason} -> offset
    end
  end
end
