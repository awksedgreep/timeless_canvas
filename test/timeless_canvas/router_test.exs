defmodule TimelessCanvas.RouterTest.MultiRouter do
  use Phoenix.Router

  import Phoenix.LiveView.Router
  import TimelessCanvas.Router

  live_canvas("/canvas", session: %{"tenant" => "one"})
  live_canvas("/ops/canvas", session: %{"tenant" => "two"})
end

defmodule TimelessCanvas.RouterTest do
  use ExUnit.Case, async: false

  alias Phoenix.LiveView.Socket
  alias TimelessCanvas.Web.Hooks

  test "the macro supports multiple mounts without live-session collisions" do
    paths = Enum.map(TimelessCanvas.RouterTest.MultiRouter.__routes__(), & &1.path)
    assert "/canvas" in paths
    assert "/canvas/:id" in paths
    assert "/ops/canvas" in paths
    assert "/ops/canvas/:id" in paths
  end

  test "the config hook accepts local paths and rejects redirect-like session input" do
    socket = %Socket{assigns: %{__changed__: %{}}}

    assert {:cont, socket} =
             Hooks.on_mount(:assign_config, %{}, %{"tc_base_path" => "/ops/canvas"}, socket)

    assert socket.assigns.tc_base_path == "/ops/canvas"

    for path <- ["javascript:alert(1)", "//evil.example", "https://evil.example", nil] do
      assert {:cont, socket} =
               Hooks.on_mount(:assign_config, %{}, %{"tc_base_path" => path}, socket)

      assert socket.assigns.tc_base_path == "/canvas"
    end
  end

  test "current_user and required config accessors fail safely and clearly" do
    assert TimelessCanvas.current_user(nil) == nil
    assert TimelessCanvas.current_user(%{}) == nil
    assert TimelessCanvas.current_user(%{assigns: %{current_user: %{id: 1}}}) == %{id: 1}

    old = Application.get_env(:timeless_canvas, :repo)
    Application.delete_env(:timeless_canvas, :repo)

    on_exit(fn ->
      if old,
        do: Application.put_env(:timeless_canvas, :repo, old),
        else: Application.delete_env(:timeless_canvas, :repo)
    end)

    assert_raise ArgumentError, ~r/missing config :timeless_canvas, :repo/, fn ->
      TimelessCanvas.repo()
    end
  end
end
