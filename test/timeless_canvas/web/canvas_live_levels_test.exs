defmodule TimelessCanvas.Web.CanvasLiveLevelsTest do
  # async: false — shares FakePersistence and the StreamManager singleton.
  use TimelessCanvas.ConnCase, async: false

  alias TimelessCanvas.Canvas
  alias TimelessCanvas.Canvas.Serializer
  alias TimelessCanvas.Components.CanvasComponents
  alias TimelessCanvas.DataQueries
  alias TimelessCanvas.StreamManager

  defp seed(user, meta) do
    {canvas, _} =
      Canvas.add_element(Canvas.new(snap_to_grid: false), %{
        type: :log_stream,
        x: 100.0,
        y: 100.0,
        width: 360.0,
        height: 200.0,
        label: "logs",
        meta: meta
      })

    data = canvas |> Serializer.encode() |> Jason.encode!() |> Jason.decode!()
    FakePersistence.seed_canvas(%{user_id: user.id, data: data})
  end

  defp prepend(view, canvas_id, entries) do
    Phoenix.PubSub.broadcast(
      TimelessCanvas.TestPubSub,
      StreamManager.stream_topic(canvas_id),
      {:stream_entries, "el-1", entries}
    )

    :sys.get_state(view.pid)
    :ok
  end

  defp entry(level, message) do
    DataQueries.put_entry_id(%{
      timestamp: System.system_time(:millisecond),
      level: level,
      message: message,
      metadata: %{}
    })
  end

  setup %{conn: conn} do
    user = test_user()
    {:ok, conn: log_in_user(conn, user), user: user}
  end

  describe "log_level_color/1" do
    test "the levels it had are the colours they were" do
      assert CanvasComponents.log_level_color(:error) == "#ef4444"
      assert CanvasComponents.log_level_color(:warning) == "#f59e0b"
      assert CanvasComponents.log_level_color(:info) == "#22c55e"
      assert CanvasComponents.log_level_color(:debug) == "#94a3b8"
      assert CanvasComponents.log_level_color(:whatever) == "#94a3b8"
      assert CanvasComponents.log_level_color(nil) == "#94a3b8"
    end

    test "notice has a colour of its own, and the levels past error one of theirs" do
      notice = CanvasComponents.log_level_color(:notice)

      refute notice in [
               CanvasComponents.log_level_color(:info),
               CanvasComponents.log_level_color(:warning),
               CanvasComponents.log_level_color(:debug)
             ]

      for level <- [:critical, :alert, :emergency] do
        assert CanvasComponents.log_level_color(level) == "#dc2626"
      end
    end

    test "a level is the same colour as an atom, as text, and in any case" do
      for level <- ~w(debug info notice warning error critical alert emergency) do
        colour = CanvasComponents.log_level_color(String.to_existing_atom(level))

        assert CanvasComponents.log_level_color(level) == colour
        assert CanvasComponents.log_level_color(String.upcase(level)) == colour
      end

      assert CanvasComponents.log_level_color("warn") ==
               CanvasComponents.log_level_color(:warning)
    end

    test "what is not a level is grey, and does not raise" do
      for level <- [42, %{}, [], "", "loud", {:a, :b}] do
        assert CanvasComponents.log_level_color(level) == "#94a3b8"
      end
    end
  end

  describe "rows" do
    test "a notice is written in its colour", %{conn: conn, user: user} do
      record = seed(user, %{})
      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
      render_async(view)

      prepend(view, record.id, [entry("notice", "sleep[66900] exited 1 after 394ms")])

      assert has_element?(
               view,
               ~s([data-element-id="el-1"] text[fill="#38bdf8"]),
               "[NOTI] sleep[66900] exited 1"
             )
    end

    test "a popover has room for the longest level", %{conn: conn, user: user} do
      record = seed(user, %{})
      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
      render_async(view)

      for {level, width} <- [{:info, "32"}, {:warning, "32"}, {:emergency, "39.8"}] do
        row = entry(level, "at #{level}")
        prepend(view, record.id, [row])
        render_hook(view, "stream:entry_click", %{"element_id" => "el-1", "entry_id" => row.id})

        assert has_element?(view, ~s(.stream-popover rect[width="#{width}"][height="12"])),
               "#{level}"

        assert has_element?(view, ".stream-popover text", String.upcase(to_string(level)))
      end
    end
  end

  describe "the level of a log stream" do
    test "is chosen from the levels there are", %{conn: conn, user: user} do
      record = seed(user, %{"host" => "web-01"})
      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
      render_hook(view, "element:select", %{"id" => "el-1"})

      options =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s(#element-meta-form select[name="level"] option))
        |> Enum.map(&(&1 |> LazyHTML.attribute("value") |> List.first()))

      assert options ==
               ["" | ~w(debug info notice warning error critical alert emergency)]

      refute has_element?(view, ~s(#element-meta-form input[name="level"]))

      assert has_element?(
               view,
               ~s(#element-meta-form select[name="level"] option[value=""][selected])
             )
    end

    test "choosing notice asks the backend for notice", %{conn: conn, user: user} do
      record = seed(user, %{"host" => "web-01"})
      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
      render_hook(view, "element:select", %{"id" => "el-1"})

      render_hook(view, "property:update_meta", %{"element_id" => "el-1", "level" => "notice"})

      meta = :sys.get_state(view.pid).socket.assigns.canvas.elements["el-1"].meta
      assert meta["level"] == "notice"
      assert DataQueries.build_log_opts(meta)[:level] == :notice
      assert has_element?(view, ~s(select[name="level"] option[value="notice"][selected]))
    end

    test "a level it has that is none of them is kept as it is", %{conn: conn, user: user} do
      record = seed(user, %{"host" => "web-01", "level" => "loud"})
      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
      render_hook(view, "element:select", %{"id" => "el-1"})

      assert has_element?(view, ~s(select[name="level"] option[value="loud"][selected]))

      meta = :sys.get_state(view.pid).socket.assigns.canvas.elements["el-1"].meta
      assert meta["level"] == "loud"
      refute Keyword.has_key?(DataQueries.build_log_opts(meta), :level)
    end

    test "a level of all, which it could be given before, is kept", %{conn: conn, user: user} do
      record = seed(user, %{"host" => "web-01", "level" => "all"})
      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
      render_hook(view, "element:select", %{"id" => "el-1"})

      assert has_element?(view, ~s(select[name="level"] option[value="all"][selected]))
    end
  end
end
