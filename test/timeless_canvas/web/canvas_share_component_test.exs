defmodule TimelessCanvas.Web.CanvasShareComponentTest do
  use ExUnit.Case, async: false

  alias Phoenix.LiveView.Socket
  alias TimelessCanvas.Test.FakePersistence
  alias TimelessCanvas.Web.CanvasShareComponent

  defmodule OwnerOnlyAuth do
    @behaviour TimelessCanvas.Auth
    def admin?(_), do: false
    def authorize(%{id: id}, %{user_id: id}, _action), do: :ok
    def authorize(_, _, _), do: {:error, :unauthorized}
  end

  setup do
    previous_persistence = Application.get_env(:timeless_canvas, :persistence)
    previous_auth = Application.get_env(:timeless_canvas, :auth)
    Application.put_env(:timeless_canvas, :persistence, FakePersistence)
    Application.put_env(:timeless_canvas, :auth, OwnerOnlyAuth)
    FakePersistence.reset()

    canvas = FakePersistence.seed_canvas(%{user_id: 1})
    target = %{id: 2, username: "target"}
    FakePersistence.seed_user(target)

    on_exit(fn ->
      Application.put_env(:timeless_canvas, :persistence, previous_persistence)
      Application.put_env(:timeless_canvas, :auth, previous_auth)
    end)

    %{canvas: canvas, target: target}
  end

  test "a viewer cannot forge a grant event", %{canvas: canvas} do
    socket = socket(canvas.id, %{id: 3})

    assert {:noreply, socket} =
             CanvasShareComponent.handle_event(
               "grant",
               %{"username" => "target", "role" => "editor"},
               socket
             )

    assert socket.assigns.error == "Not authorized to share this canvas"
    assert FakePersistence.list_access(canvas.id) == []
  end

  test "owner role escalation is rejected", %{canvas: canvas} do
    socket = socket(canvas.id, %{id: 1})

    assert {:noreply, socket} =
             CanvasShareComponent.handle_event(
               "grant",
               %{"username" => "target", "role" => "owner"},
               socket
             )

    assert socket.assigns.error == "Invalid sharing role"
    assert FakePersistence.list_access(canvas.id) == []
  end

  test "malformed revoke ids do not crash", %{canvas: canvas} do
    socket = socket(canvas.id, %{id: 1})

    assert {:noreply, socket} =
             CanvasShareComponent.handle_event("revoke", %{"user-id" => "bad"}, socket)

    assert socket.assigns.error == "Could not revoke access"
  end

  defp socket(canvas_id, current_user) do
    %Socket{assigns: %{__changed__: %{}, canvas_id: canvas_id, current_user: current_user}}
  end
end
