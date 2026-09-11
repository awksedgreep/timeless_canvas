defmodule TimelessCanvas.Web.CanvasLiveAlertTest do
  @moduledoc """
  Alert controls in the properties panel.

  The point of defining a rule here is that the selector is already known to
  be correct — it is the one drawing the graph. These tests hold that line,
  and hold the validation that stops a half-filled form becoming a rule that
  fires constantly.
  """
  use TimelessCanvas.ConnCase, async: false

  alias TimelessCanvas.Canvas
  alias TimelessCanvas.Canvas.Serializer
  alias TimelessCanvas.Components.CanvasComponents

  defmodule StubBackend do
    @moduledoc false
    @behaviour TimelessCanvas.AlertSource

    @impl true
    def list_rules(element) do
      send(:alert_ui_probe, {:list, element.id})
      {:ok, Agent.get(__MODULE__, & &1)}
    end

    @impl true
    def create_rule(element, attrs) do
      send(:alert_ui_probe, {:create, element, attrs})

      rule = %{
        id: 1,
        name: attrs["name"],
        metric: element.meta["metric_name"],
        labels: %{},
        condition: attrs["condition"],
        threshold: attrs["threshold"],
        duration: attrs["duration"],
        aggregate: attrs["aggregate"],
        enabled: true
      }

      Agent.update(__MODULE__, &(&1 ++ [rule]))
      {:ok, 1}
    end

    @impl true
    def update_rule(id, attrs) do
      send(:alert_ui_probe, {:update, id, attrs})
      :ok
    end

    @impl true
    def delete_rule(id) do
      send(:alert_ui_probe, {:delete, id})
      Agent.update(__MODULE__, fn rules -> Enum.reject(rules, &(&1.id == id)) end)
      :ok
    end

    @impl true
    def delivery_formats, do: [{"ntfy", "ntfy"}, {"generic", "Generic JSON"}]

    @impl true
    def list_all_rules(actor) do
      send(:alert_ui_probe, {:list_all, actor.id})
      {:ok, Agent.get(__MODULE__, & &1)}
    end

    @impl true
    def list_history(rule_id, opts) do
      send(:alert_ui_probe, {:history, rule_id, opts})
      {:ok, [%{id: 91, status: :firing, acknowledged: false}]}
    end

    @impl true
    def acknowledge_alert(alert_id, actor) do
      send(:alert_ui_probe, {:acknowledge, alert_id, actor.id})
      :ok
    end
  end

  defp encode(canvas), do: canvas |> Serializer.encode() |> Jason.encode!() |> Jason.decode!()

  defp graph_canvas(user, meta) do
    {canvas, el} =
      Canvas.add_element(Canvas.new(snap_to_grid: false), %{
        type: :graph,
        x: 10.0,
        y: 10.0,
        label: "CPU",
        meta: meta
      })

    {FakePersistence.seed_canvas(%{user_id: user.id, data: encode(canvas)}), el}
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  setup %{conn: conn} do
    Process.register(self(), :alert_ui_probe)

    start_supervised!(%{
      id: StubBackend,
      start: {Agent, :start_link, [fn -> [] end, [name: StubBackend]]}
    })

    Application.put_env(:timeless_canvas, :alert_backend, StubBackend)
    on_exit(fn -> Application.delete_env(:timeless_canvas, :alert_backend) end)

    user = test_user()
    {:ok, conn: log_in_user(conn, user), user: user}
  end

  test "selecting a graph loads its rules", %{conn: conn, user: user} do
    {record, el} = graph_canvas(user, %{"metric_name" => "cpu_usage", "host" => "web-1"})
    {:ok, view, _html} = live(conn, "/canvas/#{record.id}")

    render_hook(view, "element:select", %{"id" => el.id})

    assert_received {:list, id}
    assert id == el.id
  end

  test "a rule is created from the element, not from typed metric or labels", %{
    conn: conn,
    user: user
  } do
    {record, el} = graph_canvas(user, %{"metric_name" => "cpu_usage", "host" => "web-1"})
    {:ok, view, _html} = live(conn, "/canvas/#{record.id}")

    render_hook(view, "element:select", %{"id" => el.id})
    render_hook(view, "alert:new", %{})

    render_hook(view, "alert:save", %{
      "name" => "CPU high",
      "condition" => "above",
      "threshold" => "90",
      "duration" => "60",
      "aggregate" => "avg",
      "webhook_url" => "https://ntfy.sh/ops",
      "webhook_format" => "ntfy"
    })

    assert_received {:create, element, attrs}

    # The backend receives the element and derives the selector itself.
    assert element.id == el.id
    assert element.meta["metric_name"] == "cpu_usage"
    refute Map.has_key?(attrs, "metric")
    refute Map.has_key?(attrs, "labels")

    assert attrs["threshold"] == 90.0
    assert attrs["duration"] == 60
  end

  test "a variable-backed selector is resolved to its current literal before creation", %{
    conn: conn,
    user: user
  } do
    {canvas, el} =
      Canvas.add_element(
        %{Canvas.new(snap_to_grid: false) | variables: %{"host" => %{"current" => "web-9"}}},
        %{
          type: :graph,
          x: 10.0,
          y: 10.0,
          label: "CPU",
          meta: %{"metric_name" => "cpu_usage", "host" => "$host"}
        }
      )

    record = FakePersistence.seed_canvas(%{user_id: user.id, data: encode(canvas)})
    {:ok, view, _html} = live(conn, "/canvas/#{record.id}")

    render_hook(view, "element:select", %{"id" => el.id})
    render_hook(view, "alert:new", %{})

    render_hook(view, "alert:save", %{
      "name" => "resolved",
      "condition" => "above",
      "threshold" => "90",
      "duration" => "0",
      "aggregate" => "avg"
    })

    assert_received {:create, created_from, _attrs}
    assert created_from.meta["host"] == "web-9"
  end

  test "an alert threshold is included in graph rendering geometry" do
    {_record, element} =
      graph_canvas(%{id: 1}, %{"metric_name" => "cpu_usage", "y_min" => "0", "y_max" => "100"})

    rule = %{id: 1, name: "CPU high", threshold: 80.0, enabled: true}
    payload = CanvasComponents.compact_graph_payload(element, [{1_000, 50.0}], nil, [rule])

    assert [%{label: "CPU high", y: y}] = payload.thresholds
    assert is_float(y)
  end

  test "a notification URL requires an explicit payload format", %{conn: conn, user: user} do
    {record, el} = graph_canvas(user, %{"metric_name" => "cpu_usage"})
    {:ok, view, _html} = live(conn, "/canvas/#{record.id}")

    render_hook(view, "element:select", %{"id" => el.id})
    render_hook(view, "alert:new", %{})

    render_hook(view, "alert:save", %{
      "name" => "notify",
      "condition" => "above",
      "threshold" => "90",
      "duration" => "0",
      "aggregate" => "avg",
      "webhook_url" => "https://ntfy.sh/ops",
      "webhook_format" => ""
    })

    refute_received {:create, _element, _attrs}
    assert assigns(view).alert_error =~ "Notification format"
  end

  test "toggle and delete accept only ids listed for the selected element", %{
    conn: conn,
    user: user
  } do
    {record, el} = graph_canvas(user, %{"metric_name" => "cpu_usage"})
    {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
    render_hook(view, "element:select", %{"id" => el.id})
    render_hook(view, "alert:new", %{})

    render_hook(view, "alert:save", %{
      "name" => "scoped",
      "condition" => "above",
      "threshold" => "90",
      "duration" => "0",
      "aggregate" => "avg"
    })

    render_hook(view, "alert:toggle", %{"id" => "999", "value" => "on"})
    render_hook(view, "alert:delete", %{"id" => "999"})
    refute_received {:update, 999, _attrs}
    refute_received {:delete, 999}

    render_hook(view, "alert:toggle", %{"id" => "1", "value" => "on"})
    assert_received {:update, 1, %{"enabled" => true}}
    render_hook(view, "alert:delete", %{"id" => "1"})
    assert_received {:delete, 1}
  end

  test "a blank threshold is refused rather than saved as zero", %{conn: conn, user: user} do
    # Coerced to 0, an "above" rule fires on every evaluation forever and the
    # operator has no idea why.
    {record, el} = graph_canvas(user, %{"metric_name" => "cpu_usage"})
    {:ok, view, _html} = live(conn, "/canvas/#{record.id}")

    render_hook(view, "element:select", %{"id" => el.id})
    render_hook(view, "alert:new", %{})

    render_hook(view, "alert:save", %{
      "name" => "no threshold",
      "condition" => "above",
      "threshold" => "",
      "duration" => "0",
      "aggregate" => "avg"
    })

    refute_received {:create, _element, _attrs}
    assert assigns(view).alert_error =~ "Threshold"
  end

  test "a blank name is refused", %{conn: conn, user: user} do
    {record, el} = graph_canvas(user, %{"metric_name" => "cpu_usage"})
    {:ok, view, _html} = live(conn, "/canvas/#{record.id}")

    render_hook(view, "element:select", %{"id" => el.id})
    render_hook(view, "alert:new", %{})

    render_hook(view, "alert:save", %{
      "name" => "   ",
      "condition" => "above",
      "threshold" => "90",
      "duration" => "0",
      "aggregate" => "avg"
    })

    refute_received {:create, _element, _attrs}
    assert assigns(view).alert_error =~ "Name"
  end

  test "an element with no metric offers no alert controls", %{conn: conn, user: user} do
    {record, el} = graph_canvas(user, %{})
    {:ok, view, _html} = live(conn, "/canvas/#{record.id}")

    render_hook(view, "element:select", %{"id" => el.id})

    # Nothing to alert on, so nothing is offered — and no backend call is made.
    refute_received {:list, _id}
    assert assigns(view).alert_rules == []
  end

  test "with no backend configured the panel offers nothing", %{conn: conn, user: user} do
    Application.delete_env(:timeless_canvas, :alert_backend)

    {record, el} = graph_canvas(user, %{"metric_name" => "cpu_usage"})
    {:ok, view, html} = live(conn, "/canvas/#{record.id}")

    render_hook(view, "element:select", %{"id" => el.id})

    refute_received {:list, _id}
    refute html =~ "Add alert"
  end

  test "a backend error is reported rather than shown as no alerts", %{conn: conn, user: user} do
    defmodule FailingBackend do
      @moduledoc false
      def list_rules(_element), do: {:error, :unavailable}
      def create_rule(_element, _attrs), do: {:error, :unavailable}
      def update_rule(_id, _attrs), do: {:error, :unavailable}
      def delete_rule(_id), do: {:error, :unavailable}
    end

    Application.put_env(:timeless_canvas, :alert_backend, FailingBackend)

    {record, el} = graph_canvas(user, %{"metric_name" => "cpu_usage"})
    {:ok, view, _html} = live(conn, "/canvas/#{record.id}")

    render_hook(view, "element:select", %{"id" => el.id})

    # "No alerts on this metric" would be the most misleading possible answer.
    assert assigns(view).alert_error =~ "Could not load alerts"
  end

  test "the central console exposes orphaned rules, history, and acknowledgement", %{
    conn: conn,
    user: user
  } do
    Agent.update(StubBackend, fn _ ->
      [
        %{
          id: 7,
          name: "Orphan",
          aggregate: "avg",
          condition: "above",
          threshold: 90,
          element_id: "el-missing"
        }
      ]
    end)

    {record, _el} = graph_canvas(user, %{"metric_name" => "cpu_usage"})
    {:ok, view, _html} = live(conn, "/canvas/#{record.id}")

    html = render_hook(view, "alerts:toggle_console", %{})
    assert_received {:list_all, user_id}
    assert user_id == user.id
    assert html =~ "Orphan"
    assert html =~ "orphaned element"

    html = render_hook(view, "alerts:history", %{"id" => "7"})
    assert_received {:history, 7, [limit: 50]}
    assert html =~ "firing"

    render_hook(view, "alerts:acknowledge", %{"id" => "91"})
    assert_received {:acknowledge, 91, user_id}
    assert user_id == user.id
  end
end
