defmodule TimelessCanvas.Router do
  @moduledoc """
  Provides a `live_canvas/2` macro for mounting the canvas editor in your router.

  ## Usage

      import TimelessCanvas.Router

      scope "/" do
        pipe_through [:browser, :require_authenticated_user]

        live_canvas "/canvas",
          on_mount: [{MyAppWeb.Auth, :ensure_authenticated}]
      end

  This generates:
  - `GET /canvas` — canvas listing page
  - `GET /canvas/:id` — canvas editor
  """

  @doc """
  Mounts the TimelessCanvas LiveView routes at the given path.

  ## Options

  - `:on_mount` — list of `on_mount` hooks to add to the live session
    (e.g. authentication hooks). Default: `[]`
  """
  defmacro live_canvas(path, opts \\ []) do
    on_mount_hooks = Keyword.get(opts, :on_mount, [])

    quote do
      live_session :timeless_canvas,
        on_mount:
          [{TimelessCanvas.Web.Hooks, :assign_config}] ++ unquote(on_mount_hooks),
        session: %{"tc_base_path" => unquote(path)} do
        live unquote(path), TimelessCanvas.Web.CanvasListLive
        live unquote(path) <> "/:id", TimelessCanvas.Web.CanvasLive
      end
    end
  end
end
