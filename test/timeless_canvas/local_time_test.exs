defmodule TimelessCanvas.LocalTimeTest do
  # async: false — one test replaces the time zone database, which is global.
  use ExUnit.Case, async: false

  alias TimelessCanvas.LocalTime

  # 2026-09-29 21:44:05.250 UTC
  @moment 1_790_718_245_250

  defmodule SummerTimeDatabase do
    @moduledoc "One zone, four hours behind UTC until October and five after."
    @behaviour Calendar.TimeZoneDatabase

    @impl true
    def time_zone_period_from_utc_iso_days(iso_days, "Test/Zone") do
      {:ok, october} = NaiveDateTime.new(2026, 10, 1, 0, 0, 0)

      moment =
        iso_days
        |> Calendar.ISO.naive_datetime_from_iso_days()
        |> then(fn {y, m, d, h, min, s, us} -> NaiveDateTime.new!(y, m, d, h, min, s, us) end)

      if NaiveDateTime.compare(moment, october) == :lt,
        do: {:ok, %{utc_offset: -18_000, std_offset: 3600, zone_abbr: "TDT"}},
        else: {:ok, %{utc_offset: -18_000, std_offset: 0, zone_abbr: "TST"}}
    end

    def time_zone_period_from_utc_iso_days(_iso_days, _zone),
      do: {:error, :time_zone_not_found}

    @impl true
    def time_zone_periods_from_wall_datetime(_naive, _zone), do: {:error, :time_zone_not_found}
  end

  defp with_database(database, fun) do
    previous = Calendar.get_time_zone_database()
    Calendar.put_time_zone_database(database)

    try do
      fun.()
    after
      Calendar.put_time_zone_database(previous)
    end
  end

  describe "from_client/1" do
    test "takes a zone and an offset east of UTC, in minutes" do
      assert LocalTime.from_client(%{"zone" => "America/New_York", "offset_minutes" => -240}) ==
               %{zone: "America/New_York", offset: -14_400}

      assert LocalTime.from_client(%{"zone" => "Asia/Kolkata", "offset_minutes" => 330}) ==
               %{zone: "Asia/Kolkata", offset: 19_800}

      assert LocalTime.from_client(%{"zone" => "Etc/GMT+5", "offset_minutes" => -300}).zone ==
               "Etc/GMT+5"
    end

    test "what is not plainly a zone or an offset is UTC" do
      utc = LocalTime.utc()

      for params <- [
            nil,
            "UTC",
            [],
            %{},
            %{"zone" => 5, "offset_minutes" => "60"},
            %{"zone" => "", "offset_minutes" => nil},
            %{"zone" => "../../etc/passwd", "offset_minutes" => 1.5},
            %{"zone" => "A B", "offset_minutes" => 100_000},
            %{"zone" => String.duplicate("a", 65), "offset_minutes" => -100_000},
            %{"zone" => "America/New_York\n", "offset_minutes" => :atom}
          ] do
        assert LocalTime.from_client(params) == utc, inspect(params)
      end
    end

    test "UTC by any of its names is the clock the server started with" do
      for name <- ["UTC", "Etc/UTC", "Etc/GMT", "GMT", "Zulu"] do
        assert LocalTime.from_client(%{"zone" => name, "offset_minutes" => 0}) == LocalTime.utc()
      end

      # London is at no distance from UTC in winter, and is not UTC.
      assert LocalTime.from_client(%{"zone" => "Europe/London", "offset_minutes" => 0}) ==
               %{zone: "Europe/London", offset: 0}
    end

    test "each is taken or left on its own" do
      assert LocalTime.from_client(%{"zone" => "<script>", "offset_minutes" => -240}) ==
               %{zone: nil, offset: -14_400}

      assert LocalTime.from_client(%{"zone" => "Europe/Paris", "offset_minutes" => 9999}) ==
               %{zone: "Europe/Paris", offset: 0}
    end
  end

  describe "format/4" do
    test "UTC is what it was" do
      assert LocalTime.format(@moment, LocalTime.utc(), "%H:%M:%S") == "21:44:05"
    end

    test "an offset moves the clock, and the day with it" do
      west = %{zone: nil, offset: -14_400}
      east = %{zone: nil, offset: 19_800}

      assert LocalTime.format(@moment, west, "%b %-d %H:%M:%S") == "Sep 29 17:44:05"
      assert LocalTime.format(@moment, east, "%b %-d %H:%M:%S") == "Sep 30 03:14:05"
    end

    test "a zone with no database to look it up in falls to the offset" do
      tz = %{zone: "America/New_York", offset: -14_400}

      with_database(Calendar.UTCOnlyTimeZoneDatabase, fn ->
        assert LocalTime.format(@moment, tz, "%H:%M") == "17:44"
      end)
    end

    test "a zone with a database gets each side of a change right" do
      # The browser was opened in summer time: four hours behind.
      tz = %{zone: "Test/Zone", offset: -14_400}
      november = @moment + 40 * 86_400_000

      with_database(SummerTimeDatabase, fn ->
        assert LocalTime.format(@moment, tz, "%H:%M") == "17:44"
        assert LocalTime.format(november, tz, "%H:%M") == "16:44"
      end)

      # Without the database the offset of the day it was opened is all
      # there is, and November is an hour out. That is the cost of having
      # none, and is what the moduledoc says.
      with_database(Calendar.UTCOnlyTimeZoneDatabase, fn ->
        assert LocalTime.format(november, tz, "%H:%M") == "17:44"
      end)
    end

    test "a zone the database does not know falls to the offset" do
      with_database(SummerTimeDatabase, fn ->
        assert LocalTime.format(@moment, %{zone: "No/Where", offset: 3600}, "%H:%M") == "22:44"
      end)
    end

    test "a moment no clock has is the fallback, and does not raise" do
      huge = 9_999_999_999_999_999_999

      assert LocalTime.format(huge, LocalTime.utc(), "%H:%M", "--") == "--"
      assert LocalTime.format(nil, LocalTime.utc(), "%H:%M", "--") == "--"
      assert LocalTime.shift("soon", LocalTime.utc()) == :error
    end
  end

  describe "today/1" do
    test "is the viewer's day" do
      now = System.system_time(:millisecond)

      for offset <- [-43_200, -14_400, 0, 19_800, 50_400] do
        tz = %{zone: nil, offset: offset}
        {:ok, local} = LocalTime.shift(now, tz)
        # A test that straddles midnight on that clock would be a day out.
        assert Date.diff(LocalTime.today(tz), NaiveDateTime.to_date(local)) in [0, 1]
      end
    end
  end

  describe "to_ms/1" do
    test "reads seconds, milliseconds, microseconds, and nanoseconds" do
      assert LocalTime.to_ms(1_790_718_245) == {:ok, @moment - 250}
      assert LocalTime.to_ms(1_790_718_245_250) == {:ok, @moment}
      assert LocalTime.to_ms(1_790_718_245_250_123) == {:ok, @moment}
      assert LocalTime.to_ms(1_790_718_245_250_123_456) == {:ok, @moment}
      assert LocalTime.to_ms(DateTime.from_unix!(@moment, :millisecond)) == {:ok, @moment}
    end

    test "what is not a time is an error" do
      for bad <- [0, -5, nil, "1790718245", 1.5, %{}] do
        assert LocalTime.to_ms(bad) == :error
      end
    end
  end
end
