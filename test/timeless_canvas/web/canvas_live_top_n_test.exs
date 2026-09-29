defmodule TimelessCanvas.Web.CanvasLiveTopNTest do
  # async: false — shares FakePersistence, FakeDataSource, and the
  # DataSource.Manager singleton.
  use TimelessCanvas.ConnCase, async: false

  alias TimelessCanvas.Canvas
  alias TimelessCanvas.Canvas.Serializer
  alias TimelessCanvas.DataSource.Manager
  alias TimelessCanvas.DataSource.Stub

  @manager_table :timeless_canvas_data_source

  @rows [
    %{labels: %{"comm" => "beam.smp", "user" => "app"}, value: 3.5},
    %{labels: %{"comm" => "postgres", "user" => "postgres"}, value: 1.75},
    %{labels: %{"comm" => "sshd", "user" => "root"}, value: 0.0}
  ]

  defp encode(canvas), do: canvas |> Serializer.encode() |> Jason.encode!() |> Jason.decode!()

  defp seed(user, elements, variables \\ %{}) do
    canvas =
      Enum.reduce(elements, Canvas.new(snap_to_grid: false), fn attrs, canvas ->
        canvas |> Canvas.add_element(attrs) |> elem(0)
      end)

    canvas = %{canvas | variables: variables}
    FakePersistence.seed_canvas(%{user_id: user.id, data: encode(canvas)})
  end

  defp top_n(meta \\ %{}) do
    %{
      type: :top_n,
      label: "CPU",
      width: 260.0,
      height: 170.0,
      meta:
        Map.merge(
          %{"host" => "web-01", "metric_name" => "proc_cpu_seconds_total", "group_by" => "comm"},
          meta
        )
    }
  end

  defp graph(meta) do
    %{
      type: :graph,
      label: "cpu",
      meta: Map.merge(%{"host" => "web-01", "metric_name" => "cpu_usage"}, meta)
    }
  end

  # The Manager republishes its own backend whenever elements register, so
  # the swap has to reach its state as well as the published row.
  defp use_backend_without_cross_series do
    %{module: module, ds_state: ds_state} = :sys.get_state(Manager)
    put_backend(Stub, %{})
    on_exit(fn -> put_backend(module, ds_state) end)
  end

  defp put_backend(module, ds_state) do
    :sys.replace_state(Manager, &%{&1 | module: module, ds_state: ds_state})
    :ets.insert(@manager_table, {:source, module, ds_state})
  end

  setup %{conn: conn} do
    user = test_user()
    {:ok, conn: log_in_user(conn, user), user: user}
  end

  describe "rendering" do
    test "draws ranked rows named by their group", %{conn: conn, user: user} do
      FakeDataSource.put(:top_series, {:ok, @rows})
      record = seed(user, [top_n()])

      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
      html = render_async(view)

      assert html =~ "CPU | proc_cpu_seconds_total"
      assert html =~ "beam.smp"
      assert html =~ "postgres"
      assert has_element?(view, ~s([data-element-id="el-1"] [data-top-index="0"]))
      assert has_element?(view, ~s([data-element-id="el-1"] [data-top-index="2"]))
      refute has_element?(view, ~s([data-top-index="3"]))
    end

    test "passes bounded options from the element's meta", %{conn: conn, user: user} do
      test_pid = self()

      FakeDataSource.put(:top_series, fn _element, opts ->
        send(test_pid, {:top_opts, opts})
        {:ok, @rows}
      end)

      record =
        seed(user, [
          top_n(%{
            "group_by" => "comm, user",
            "limit" => "9999",
            "order" => "asc",
            "window" => "x"
          })
        ])

      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
      render_async(view)

      assert_receive {:top_opts, opts}
      assert opts[:group_by] == ["comm", "user"]
      assert opts[:limit] == 50
      assert opts[:order] == :asc
      assert opts[:aggregate] == :sum
      refute Keyword.has_key?(opts, :window)
    end

    test "a label filter reaches the backend as matchers", %{conn: conn, user: user} do
      test_pid = self()

      FakeDataSource.put(:top_series, fn element, opts ->
        send(test_pid, {:asked, TimelessCanvas.Canvas.Element.query_matchers(element), opts})
        {:ok, @rows}
      end)

      record =
        seed(user, [
          top_n(%{
            "metric_name" => "unit_memory_bytes",
            "group_by" => "unit",
            "label_filter" => "kind!=slice|manager",
            "window" => "30"
          })
        ])

      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
      render_async(view)

      assert_receive {:asked, matchers, opts}
      assert matchers == [{"host", :eq, ["web-01"]}, {"kind", :neq, ["slice", "manager"]}]
      assert opts[:window] == 30
    end

    test "shows only as many rows as fit the element", %{conn: conn, user: user} do
      FakeDataSource.put(:top_series, {:ok, @rows})
      record = seed(user, [Map.put(top_n(), :height, 50.0)])

      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
      render_async(view)

      assert has_element?(view, ~s([data-top-index="1"]))
      refute has_element?(view, ~s([data-top-index="2"]))
    end

    test "a failed query reads differently from an empty one", %{conn: conn, user: user} do
      FakeDataSource.put(:top_series, {:error, :too_many_series})
      record = seed(user, [top_n()])

      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
      assert render_async(view) =~ "data unavailable"

      FakeDataSource.put(:top_series, {:ok, []})
      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
      html = render_async(view)

      assert html =~ "No data"
      refute html =~ "data unavailable"
    end

    test "asks for a metric before querying", %{conn: conn, user: user} do
      FakeDataSource.put(:top_series, fn _element, _opts -> flunk("queried without a metric") end)
      record = seed(user, [top_n(%{"metric_name" => ""})])

      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")

      assert render_async(view) =~ "Choose a metric"
    end

    test "a row with no bar does not break the scale", %{conn: conn, user: user} do
      FakeDataSource.put(:top_series, {:ok, [%{labels: %{"comm" => "idle"}, value: -2.0}]})
      record = seed(user, [top_n()])

      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")

      assert render_async(view) =~ "idle"
    end
  end

  describe "placement" do
    test "is offered and places an element", %{conn: conn, user: user} do
      record = seed(user, [])
      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")

      view |> element(~s{button[phx-value-mode="place"]}) |> render_click()
      assert has_element?(view, ~s{button[phx-value-kind="top_n"]})

      render_hook(view, "set_place_kind", %{"kind" => "top_n"})
      render_hook(view, "canvas:click", %{"x" => 300, "y" => 300})

      assert has_element?(view, ~s([data-element-id="el-1"]))
      assert render(view) =~ "Choose a metric"
    end

    test "is not offered when the backend cannot rank", %{conn: conn, user: user} do
      use_backend_without_cross_series()
      record = seed(user, [])
      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")

      view |> element(~s{button[phx-value-mode="place"]}) |> render_click()

      assert has_element?(view, ~s{button[phx-value-kind="text_series"]})
      refute has_element?(view, ~s{button[phx-value-kind="top_n"]})
    end

    test "an element from another backend renders without querying", %{conn: conn, user: user} do
      use_backend_without_cross_series()
      record = seed(user, [top_n()])

      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
      html = render_async(view)

      refute Manager.supports?(:top_series)
      assert html =~ "No data"
      refute html =~ "data unavailable"
    end
  end

  describe "properties panel" do
    test "names the metric directly and offers the ranking options", %{conn: conn, user: user} do
      record = seed(user, [top_n()])
      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
      render_hook(view, "element:select", %{"id" => "el-1"})

      form = "#element-meta-form"
      assert has_element?(view, ~s(#{form} input[name="metric_name"]))
      assert has_element?(view, ~s(#{form} input[name="group_by"]))
      assert has_element?(view, ~s(#{form} input[name="limit"]))
      assert has_element?(view, ~s(#{form} input[name="label_filter"]))
      assert has_element?(view, ~s(#{form} input[name="window"]))
      assert has_element?(view, ~s(#{form} select[name="order"]))

      assert has_element?(
               view,
               ~s(#{form} select[name="aggregate"] option[value="sum"][selected])
             )

      refute has_element?(view, ~s(#{form} select[name="aggregate"] option[value=""]))
    end

    test "editing the metric requeries", %{conn: conn, user: user} do
      test_pid = self()

      FakeDataSource.put(:top_series, fn element, _opts ->
        send(test_pid, {:queried, element.meta["metric_name"]})
        {:ok, @rows}
      end)

      record = seed(user, [top_n()])
      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
      render_async(view)
      render_hook(view, "element:select", %{"id" => "el-1"})

      render_hook(view, "property:update_meta", %{
        "element_id" => "el-1",
        "metric_name" => "proc_rss_bytes"
      })

      assert_receive {:queried, "proc_rss_bytes"}
      assert render(view) =~ "CPU | proc_rss_bytes"
    end

    test "a text series can name its metric", %{conn: conn, user: user} do
      record = seed(user, [%{type: :text_series, meta: %{"host" => "web-01"}}])
      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
      render_hook(view, "element:select", %{"id" => "el-1"})

      assert has_element?(view, ~s(#element-meta-form input[name="metric_name"]))
    end
  end

  describe "graph aggregate" do
    test "is offered, and reaches the backend once set", %{conn: conn, user: user} do
      FakeDataSource.put(:metric_range, {:ok, [{1_000, 1.0}, {2_000, 2.0}]})
      record = seed(user, [graph(%{})])
      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
      render_async(view)
      render_hook(view, "element:select", %{"id" => "el-1"})

      assert has_element?(
               view,
               ~s(#element-meta-form select[name="aggregate"] option[value=""][selected])
             )

      # Unset, the graph keeps asking for the first matching series.
      assert :ets.lookup(:timeless_canvas_fake_data_source, :metric_range_opts) == []

      render_hook(view, "property:update_meta", %{"element_id" => "el-1", "aggregate" => "sum"})

      assert [{:metric_range_opts, [aggregate: :sum]}] =
               :ets.lookup(:timeless_canvas_fake_data_source, :metric_range_opts)
    end

    test "a label filter or a window alone is enough to ask the backend that can honour it", %{
      conn: conn,
      user: user
    } do
      FakeDataSource.put(:metric_range, {:ok, [{1_000, 1.0}]})

      for meta <- [%{"label_filter" => "kind!=slice"}, %{"window" => "30"}] do
        :ets.delete(:timeless_canvas_fake_data_source, :metric_range_opts)
        record = seed(user, [graph(meta)])
        {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
        render_async(view)

        assert [{:metric_range_opts, opts}] =
                 :ets.lookup(:timeless_canvas_fake_data_source, :metric_range_opts)

        refute Keyword.has_key?(opts, :aggregate)
      end
    end

    test "is not a label filter", %{conn: conn, user: user} do
      test_pid = self()

      FakeDataSource.put(:metric_range, fn element ->
        send(test_pid, {:labels, TimelessCanvas.Canvas.Element.query_labels(element)})
        {:ok, []}
      end)

      record = seed(user, [graph(%{"aggregate" => "max"})])
      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
      render_async(view)

      assert_receive {:labels, %{"host" => "web-01"} = labels}
      assert map_size(labels) == 1
    end

    test "is hidden when the backend cannot combine series", %{conn: conn, user: user} do
      use_backend_without_cross_series()
      record = seed(user, [graph(%{})])
      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
      render_hook(view, "element:select", %{"id" => "el-1"})

      assert has_element?(view, "#element-meta-form")
      refute has_element?(view, ~s(#element-meta-form select[name="aggregate"]))
      refute has_element?(view, ~s(#element-meta-form input[name="window"]))
      refute has_element?(view, ~s(#element-meta-form input[name="label_filter"]))
    end

    test "the matching series are those the label filter leaves", %{conn: conn, user: user} do
      FakeDataSource.put(:list_series_for_host, [
        {"unit_memory_bytes", %{"host" => "web-01", "unit" => "user.slice", "kind" => "slice"}},
        {"unit_memory_bytes", %{"host" => "web-01", "unit" => "pg.service", "kind" => "service"}},
        {"unit_memory_bytes", %{"host" => "web-01", "unit" => "term.scope", "kind" => "scope"}},
        {"unit_memory_bytes", %{"host" => "web-01", "unit" => "old.service"}}
      ])

      record =
        seed(user, [
          graph(%{"metric_name" => "unit_memory_bytes", "label_filter" => "kind!=slice|manager"})
        ])

      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
      html = render_hook(view, "element:select", %{"id" => "el-1"})

      assert html =~ "3 series match; the graph draws the first."
      assert has_element?(view, ".properties-panel__series-list", "pg.service")
      assert has_element?(view, ".properties-panel__series-list", "old.service")
      refute has_element?(view, ".properties-panel__series-list", "user.slice")
    end

    test "warns when several series match and none is combined", %{conn: conn, user: user} do
      FakeDataSource.put(:list_series_for_host, [
        {"cpu_usage", %{"host" => "web-01", "comm" => "beam.smp"}},
        {"cpu_usage", %{"host" => "web-01", "comm" => "postgres"}}
      ])

      record = seed(user, [graph(%{})])
      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
      html = render_hook(view, "element:select", %{"id" => "el-1"})

      assert html =~ "2 series match; the graph draws the first."
      assert html =~ "Set an aggregate to combine them."

      html =
        render_hook(view, "property:update_meta", %{"element_id" => "el-1", "aggregate" => "sum"})

      refute html =~ "series match; the graph draws the first."
    end
  end

  describe "row click" do
    @variables %{
      "comm" => %{"type" => "label", "label_key" => "comm", "current" => ""},
      "owner" => %{"type" => "label", "label_key" => "user", "current" => ""}
    }

    test "sets the variables bound to the row's group-by labels", %{conn: conn, user: user} do
      FakeDataSource.put(:top_series, {:ok, @rows})
      record = seed(user, [top_n(%{"group_by" => "comm,user"})], @variables)
      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
      render_async(view)

      render_hook(view, "top:row_click", %{"element_id" => "el-1", "index" => 1})

      variables = :sys.get_state(view.pid).socket.assigns.canvas.variables
      assert variables["comm"]["current"] == "postgres"
      assert variables["owner"]["current"] == "postgres"
    end

    test "leaves variables for labels the element does not group by", %{conn: conn, user: user} do
      FakeDataSource.put(:top_series, {:ok, @rows})
      record = seed(user, [top_n(%{"group_by" => "comm"})], @variables)
      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
      render_async(view)

      render_hook(view, "top:row_click", %{"element_id" => "el-1", "index" => 0})

      variables = :sys.get_state(view.pid).socket.assigns.canvas.variables
      assert variables["comm"]["current"] == "beam.smp"
      assert variables["owner"]["current"] == ""
    end

    test "ignores rows and elements that do not exist", %{conn: conn, user: user} do
      FakeDataSource.put(:top_series, {:ok, @rows})
      record = seed(user, [top_n(), graph(%{})], @variables)
      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
      render_async(view)

      for params <- [
            %{"element_id" => "el-1", "index" => 99},
            %{"element_id" => "el-1", "index" => -1},
            %{"element_id" => "el-1", "index" => "0"},
            %{"element_id" => "el-2", "index" => 0},
            %{"element_id" => "missing", "index" => 0},
            %{}
          ] do
        render_hook(view, "top:row_click", params)
      end

      variables = :sys.get_state(view.pid).socket.assigns.canvas.variables
      assert variables["comm"]["current"] == ""
    end
  end
end
