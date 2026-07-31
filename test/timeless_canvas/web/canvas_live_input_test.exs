defmodule TimelessCanvas.Web.CanvasLiveInputTest do
  # Phase 4b server-side coverage: escape cascade, read-only enforcement,
  # history coalescing, and input polish.
  #
  # async: false — shares FakePersistence, FakeDataSource, and the
  # DataSource.Manager / StreamManager singletons (plus per-test :auth
  # app-env swaps).
  use TimelessCanvas.ConnCase, async: false

  alias TimelessCanvas.Canvas
  alias TimelessCanvas.Canvas.Serializer
  alias TimelessCanvas.DataQueries
  alias TimelessCanvas.StreamManager

  defp encode(canvas) do
    canvas |> Serializer.encode() |> Jason.encode!() |> Jason.decode!()
  end

  defp canvas_with_element(attrs) do
    {canvas, el} = Canvas.add_element(Canvas.new(snap_to_grid: false), attrs)
    {encode(canvas), el}
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  setup %{conn: conn} do
    user = test_user()
    {:ok, conn: log_in_user(conn, user), user: user}
  end

  describe "canvas:escape cascade" do
    test "closes share, then typeahead, then exits mode, then deselects", %{
      conn: conn,
      user: user
    } do
      {data, el} = canvas_with_element(%{x: 100.0, y: 100.0, label: "esc-target"})
      record = FakePersistence.seed_canvas(%{user_id: user.id, data: data})

      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")

      # Layer the states: selection, place mode, open typeahead, share overlay
      render_hook(view, "element:select", %{"id" => el.id})
      view |> element(~s{button[phx-value-mode="place"]}) |> render_click()
      render_hook(view, "ta:open", %{"ta_id" => "place"})
      view |> element(~s{button[phx-click="toggle_share"]}) |> render_click()

      a = assigns(view)
      assert a.show_share
      assert a.ta_open == "place"
      assert a.mode == :place
      assert MapSet.member?(a.selected_ids, el.id)

      # 1st escape: share overlay closes, everything else untouched
      render_hook(view, "canvas:escape", %{})
      a = assigns(view)
      refute a.show_share
      assert a.ta_open == "place"
      assert a.mode == :place
      assert MapSet.member?(a.selected_ids, el.id)

      # 2nd escape: typeahead dropdown closes
      render_hook(view, "canvas:escape", %{})
      a = assigns(view)
      assert a.ta_open == nil
      assert a.mode == :place
      assert MapSet.member?(a.selected_ids, el.id)

      # 3rd escape: back to select mode
      render_hook(view, "canvas:escape", %{})
      a = assigns(view)
      assert a.mode == :select
      assert MapSet.member?(a.selected_ids, el.id)

      # 4th escape: deselect
      render_hook(view, "canvas:escape", %{})
      assert MapSet.size(assigns(view).selected_ids) == 0
    end

    test "closes the stream popover before deselecting", %{conn: conn, user: user} do
      {canvas, el} =
        Canvas.add_element(Canvas.new(snap_to_grid: false), %{
          type: :log_stream,
          x: 100.0,
          y: 100.0,
          label: "logs",
          meta: %{}
        })

      record = FakePersistence.seed_canvas(%{user_id: user.id, data: encode(canvas)})

      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
      render_async(view)

      entry =
        DataQueries.put_entry_id(%{
          timestamp: System.system_time(:millisecond),
          level: :info,
          message: "popover-entry",
          metadata: %{}
        })

      Phoenix.PubSub.broadcast(
        TimelessCanvas.TestPubSub,
        StreamManager.stream_topic(record.id),
        {:stream_entries, el.id, [entry]}
      )

      render(view)
      render_hook(view, "element:select", %{"id" => el.id})
      render_hook(view, "stream:entry_click", %{"element_id" => el.id, "entry_id" => entry.id})

      a = assigns(view)
      assert a.stream_popover != nil
      assert MapSet.member?(a.selected_ids, el.id)

      # 1st escape: popover closes, selection survives
      render_hook(view, "canvas:escape", %{})
      a = assigns(view)
      assert a.stream_popover == nil
      assert MapSet.member?(a.selected_ids, el.id)

      # 2nd escape: deselect
      render_hook(view, "canvas:escape", %{})
      assert MapSet.size(assigns(view).selected_ids) == 0
    end

    test "connect mode exits to select and drops the pending source", %{conn: conn, user: user} do
      {data, el} = canvas_with_element(%{x: 100.0, y: 100.0, label: "connectable"})
      record = FakePersistence.seed_canvas(%{user_id: user.id, data: data})

      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")

      view |> element(~s{button[phx-value-mode="connect"]}) |> render_click()
      render_hook(view, "element:select", %{"id" => el.id})
      assert assigns(view).connect_from == el.id

      render_hook(view, "canvas:escape", %{})
      a = assigns(view)
      assert a.mode == :select
      assert a.connect_from == nil
    end
  end

  defp with_deny_edit_auth do
    previous = Application.get_env(:timeless_canvas, :auth)
    Application.put_env(:timeless_canvas, :auth, TimelessCanvas.Test.DenyEditAuth)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:timeless_canvas, :auth)
        value -> Application.put_env(:timeless_canvas, :auth, value)
      end
    end)
  end

  describe "read-only enforcement" do
    test "viewers mount with the badge and data-can-edit=false", %{conn: conn, user: user} do
      with_deny_edit_auth()
      {data, _el} = canvas_with_element(%{x: 100.0, y: 100.0, label: "look-dont-touch"})
      record = FakePersistence.seed_canvas(%{user_id: user.id, data: data})

      {:ok, _view, html} = live(conn, "/canvas/#{record.id}")

      assert html =~ "View Only"
      assert html =~ ~s(data-can-edit="false")
    end

    test "editors mount with data-can-edit=true", %{conn: conn, user: user} do
      {data, _el} = canvas_with_element(%{label: "editable"})
      record = FakePersistence.seed_canvas(%{user_id: user.id, data: data})

      {:ok, _view, html} = live(conn, "/canvas/#{record.id}")

      assert html =~ ~s(data-can-edit="true")
      refute html =~ "View Only"
    end

    test "a denied move pushes canvas:reset-element and shows the toast once", %{
      conn: conn,
      user: user
    } do
      with_deny_edit_auth()
      {data, el} = canvas_with_element(%{x: 100.0, y: 100.0, label: "immovable"})
      record = FakePersistence.seed_canvas(%{user_id: user.id, data: data})

      {:ok, view, html} = live(conn, "/canvas/#{record.id}")
      refute html =~ "View-only canvas"

      html = render_hook(view, "element:move", %{"id" => el.id, "dx" => 40, "dy" => 0})

      id = el.id
      assert_push_event(view, "canvas:reset-element", %{id: ^id})
      assert html =~ "View-only canvas"
      assert assigns(view).canvas.elements[el.id].x == 100.0

      # A denied resize also resets; the notice does not re-trigger state
      # churn (still the same session).
      render_hook(view, "element:resize", %{"id" => el.id, "width" => 300, "height" => 300})
      assert_push_event(view, "canvas:reset-element", %{id: ^id})
      assert assigns(view).canvas.elements[el.id].width != 300.0
      assert assigns(view).view_only_notice_shown

      # The toast is dismissable.
      html = view |> element(".canvas-view-only-toast") |> render_click()
      refute html =~ "View-only canvas"
    end

    test "the toast auto-clears", %{conn: conn, user: user} do
      with_deny_edit_auth()
      {data, el} = canvas_with_element(%{x: 100.0, y: 100.0, label: "toast"})
      record = FakePersistence.seed_canvas(%{user_id: user.id, data: data})

      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")

      html = render_hook(view, "element:move", %{"id" => el.id, "dx" => 40, "dy" => 0})
      assert html =~ "View-only canvas"

      send(view.pid, :clear_view_only_toast)
      refute render(view) =~ "View-only canvas"
    end

    test "denied non-optimistic edits push no reset event", %{conn: conn, user: user} do
      with_deny_edit_auth()
      {data, el} = canvas_with_element(%{x: 100.0, y: 100.0, label: "undeletable"})
      record = FakePersistence.seed_canvas(%{user_id: user.id, data: data})

      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")

      render_hook(view, "element:select", %{"id" => el.id})
      render_hook(view, "delete_selected", %{})

      assert has_element?(view, ~s([data-element-id="#{el.id}"]))
      refute_push_event(view, "canvas:reset-element", %{}, 0)
    end
  end

  describe "history coalescing" do
    test "rapid same-field property edits become one undo step", %{conn: conn, user: user} do
      {data, el} = canvas_with_element(%{x: 100.0, y: 100.0, label: "orig"})
      record = FakePersistence.seed_canvas(%{user_id: user.id, data: data})

      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")

      render_hook(view, "property:update_element", %{
        "element_id" => el.id,
        "label" => "o",
        "_target" => ["label"]
      })

      render_hook(view, "property:update_element", %{
        "element_id" => el.id,
        "label" => "ox",
        "_target" => ["label"]
      })

      render_hook(view, "property:update_element", %{
        "element_id" => el.id,
        "label" => "oxide",
        "_target" => ["label"]
      })

      a = assigns(view)
      assert a.canvas.elements[el.id].label == "oxide"
      # Three keystrokes, one history entry
      assert length(a.history.past) == 1

      # One undo returns to the ORIGINAL value
      render_hook(view, "canvas:undo", %{})
      assert assigns(view).canvas.elements[el.id].label == "orig"
    end

    test "edits to different fields do not coalesce", %{conn: conn, user: user} do
      {data, el} = canvas_with_element(%{x: 100.0, y: 100.0, label: "orig"})
      record = FakePersistence.seed_canvas(%{user_id: user.id, data: data})

      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")

      render_hook(view, "property:update_element", %{
        "element_id" => el.id,
        "label" => "renamed",
        "_target" => ["label"]
      })

      render_hook(view, "property:update_element", %{
        "element_id" => el.id,
        "x" => "250",
        "_target" => ["x"]
      })

      assert length(assigns(view).history.past) == 2
    end

    test "meta edits coalesce per field and undo in one step", %{conn: conn, user: user} do
      {data, el} =
        canvas_with_element(%{
          x: 100.0,
          y: 100.0,
          label: "srv",
          type: :server,
          meta: %{"ip" => "10.0.0.1"}
        })

      record = FakePersistence.seed_canvas(%{user_id: user.id, data: data})

      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")

      render_hook(view, "property:update_meta", %{
        "element_id" => el.id,
        "ip" => "10.0.0.2",
        "_target" => ["ip"]
      })

      render_hook(view, "property:update_meta", %{
        "element_id" => el.id,
        "ip" => "10.0.0.25",
        "_target" => ["ip"]
      })

      a = assigns(view)
      assert a.canvas.elements[el.id].meta["ip"] == "10.0.0.25"
      assert length(a.history.past) == 1

      render_hook(view, "canvas:undo", %{})
      assert assigns(view).canvas.elements[el.id].meta["ip"] == "10.0.0.1"
    end

    test "discrete ops still append; no coalescing across an undo", %{conn: conn, user: user} do
      {data, el} = canvas_with_element(%{x: 100.0, y: 100.0, label: "orig"})
      record = FakePersistence.seed_canvas(%{user_id: user.id, data: data})

      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")

      # Two discrete moves = two entries (no op key)
      render_hook(view, "element:move", %{"id" => el.id, "dx" => 10, "dy" => 0})
      render_hook(view, "element:move", %{"id" => el.id, "dx" => 10, "dy" => 0})
      assert length(assigns(view).history.past) == 2

      # A property edit, an undo, then another rapid same-field edit: the
      # post-undo edit must get its own entry (never replace_top over the
      # restored state).
      render_hook(view, "property:update_element", %{
        "element_id" => el.id,
        "label" => "renamed",
        "_target" => ["label"]
      })

      render_hook(view, "canvas:undo", %{})
      past_after_undo = length(assigns(view).history.past)

      render_hook(view, "property:update_element", %{
        "element_id" => el.id,
        "label" => "renamed-again",
        "_target" => ["label"]
      })

      assert length(assigns(view).history.past) == past_after_undo + 1

      render_hook(view, "canvas:undo", %{})
      assert assigns(view).canvas.elements[el.id].label == "orig"
    end

    test "a typeahead-applied meta change (no _target) does not coalesce", %{
      conn: conn,
      user: user
    } do
      {data, el} =
        canvas_with_element(%{
          x: 100.0,
          y: 100.0,
          label: "srv",
          type: :server,
          meta: %{"ip" => "10.0.0.1"}
        })

      record = FakePersistence.seed_canvas(%{user_id: user.id, data: data})

      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")

      render_hook(view, "property:update_meta", %{"element_id" => el.id, "ip" => "10.0.0.2"})
      render_hook(view, "property:update_meta", %{"element_id" => el.id, "ip" => "10.0.0.3"})

      assert length(assigns(view).history.past) == 2
    end
  end

  describe "input polish" do
    test "share revoke button requires confirmation", %{conn: conn, user: user} do
      record = FakePersistence.seed_canvas(%{user_id: user.id})
      FakePersistence.seed_user(%{id: 42, username: "colleague"})
      FakePersistence.grant_access(record.id, 42, :viewer)

      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
      html = view |> element(~s{button[phx-click="toggle_share"]}) |> render_click()

      assert html =~ "colleague"
      assert has_element?(view, ~s{button[phx-click="revoke"][data-confirm]})
    end

    test "placing a host element returns to select mode like typed elements", %{
      conn: conn,
      user: user
    } do
      FakeDataSource.put(:list_hosts, ["ohm"])
      record = FakePersistence.seed_canvas(%{user_id: user.id})

      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")
      render_async(view)

      view |> element(~s{button[phx-value-mode="place"]}) |> render_click()
      view |> element(~s{input[name="ta_search"]}) |> render_focus()
      view |> element(~s{button[phx-value-value="ohm"]}) |> render_click()
      assert assigns(view).mode == :place

      view
      |> element("#canvas-svg")
      |> render_hook("canvas:click", %{"x" => 100, "y" => 100})

      assert assigns(view).mode == :select
      assert has_element?(view, ~s([data-element-id="el-1"]))
    end

    test "properties-panel text inputs and the rename input are debounced", %{
      conn: conn,
      user: user
    } do
      {data, el} = canvas_with_element(%{x: 100.0, y: 100.0, label: "debounced"})
      record = FakePersistence.seed_canvas(%{user_id: user.id, data: data})

      {:ok, view, _html} = live(conn, "/canvas/#{record.id}")

      render_hook(view, "element:select", %{"id" => el.id})

      assert has_element?(
               view,
               ~s{#element-properties-form input[name="label"][phx-debounce="300"]}
             )

      assert has_element?(view, ~s{#element-properties-form input[name="x"][phx-debounce="300"]})

      # Rename input (owner only)
      html = view |> element(".canvas-toolbar__name") |> render_click()
      assert html =~ ~s(phx-debounce="300")
    end

    test "the shortcut legend reflects the swapped nudge convention", %{conn: conn, user: user} do
      record = FakePersistence.seed_canvas(%{user_id: user.id})

      {:ok, _view, html} = live(conn, "/canvas/#{record.id}")

      assert html =~ "Nudge 1px"
      assert html =~ "Nudge grid step"
    end
  end
end
