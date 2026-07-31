defmodule TimelessCanvas.Web.CanvasListLiveTest do
  # async: false — shares the FakePersistence Agent with other suites.
  use TimelessCanvas.ConnCase, async: false

  setup %{conn: conn} do
    user = test_user()
    {:ok, conn: log_in_user(conn, user), user: user}
  end

  test "shows an empty state when the user has no canvases", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/canvas")

    assert html =~ "My Canvases"
    assert html =~ "No canvases yet"
  end

  test "lists the user's canvases", %{conn: conn, user: user} do
    FakePersistence.seed_canvas(%{name: "Alpha Canvas", user_id: user.id})
    FakePersistence.seed_canvas(%{name: "Beta Canvas", user_id: user.id})
    FakePersistence.seed_canvas(%{name: "Not Mine", user_id: user.id + 1000})

    {:ok, _view, html} = live(conn, "/canvas")

    assert html =~ "Alpha Canvas"
    assert html =~ "Beta Canvas"
    refute html =~ "Not Mine"
  end

  test "sub-canvases are labeled", %{conn: conn, user: user} do
    parent = FakePersistence.seed_canvas(%{name: "Parent", user_id: user.id})
    FakePersistence.seed_canvas(%{name: "Child", user_id: user.id, parent_id: parent.id})

    {:ok, _view, html} = live(conn, "/canvas")

    assert html =~ "Child"
    assert html =~ "sub-canvas"
  end

  test "new_canvas creates a record and redirects to the editor", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, "/canvas")

    view |> element("button", "New Canvas") |> render_click()

    assert_redirect(view, "/canvas/1")
    assert {:ok, record} = FakePersistence.get_canvas(1)
    assert record.name == "New Canvas 1"
    assert record.user_id == user.id
  end

  test "rename flow updates the canvas name", %{conn: conn, user: user} do
    record = FakePersistence.seed_canvas(%{name: "Old Name", user_id: user.id})

    {:ok, view, _html} = live(conn, "/canvas")

    view
    |> element(~s{button[phx-click="start_rename"][phx-value-id="#{record.id}"]})
    |> render_click()

    html =
      view
      |> element(~s{form[phx-submit="save_rename"]})
      |> render_submit(%{"canvas_id" => to_string(record.id), "name" => "New Name"})

    assert html =~ "New Name"
    refute html =~ "Old Name"
    assert {:ok, %{name: "New Name"}} = FakePersistence.get_canvas(record.id)
  end

  test "blank rename is ignored", %{conn: conn, user: user} do
    record = FakePersistence.seed_canvas(%{name: "Unchanged", user_id: user.id})

    {:ok, view, _html} = live(conn, "/canvas")

    view
    |> element(~s{button[phx-click="start_rename"][phx-value-id="#{record.id}"]})
    |> render_click()

    html =
      view
      |> element(~s{form[phx-submit="save_rename"]})
      |> render_submit(%{"canvas_id" => to_string(record.id), "name" => "   "})

    assert html =~ "Unchanged"
    assert {:ok, %{name: "Unchanged"}} = FakePersistence.get_canvas(record.id)
  end

  test "delete_canvas removes the canvas from the list", %{conn: conn, user: user} do
    record = FakePersistence.seed_canvas(%{name: "Doomed Canvas", user_id: user.id})

    {:ok, view, html} = live(conn, "/canvas")
    assert html =~ "Doomed Canvas"

    html =
      view
      |> element(~s{button[phx-click="delete_canvas"][phx-value-id="#{record.id}"]})
      |> render_click()

    refute html =~ "Doomed Canvas"
    assert FakePersistence.get_canvas(record.id) == {:error, :not_found}
  end

  test "owner-only actions are hidden on shared canvases", %{conn: conn, user: user} do
    other = user.id + 1000
    record = FakePersistence.seed_canvas(%{name: "Shared With Me", user_id: other})
    FakePersistence.grant_access(record.id, user.id, :viewer)

    {:ok, view, html} = live(conn, "/canvas")

    assert html =~ "Shared With Me"
    refute has_element?(view, ~s{button[phx-click="delete_canvas"]})
    refute has_element?(view, ~s{button[phx-click="start_rename"]})
  end
end
