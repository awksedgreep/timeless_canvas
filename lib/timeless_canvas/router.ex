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
  - `:session` — host session values to preserve and pass to the LiveViews
  - `:as` — unique live-session name; by default it is derived from `path`
  """
  defmacro live_canvas(path, opts \\ []) do
    {expanded_path, _binding} = Code.eval_quoted(path, [], __CALLER__)
    {expanded_opts, _binding} = Code.eval_quoted(opts, [], __CALLER__)

    unless is_binary(expanded_path) and is_list(expanded_opts) do
      raise ArgumentError, "live_canvas path and options must be compile-time literals"
    end

    on_mount_hooks = Keyword.get(expanded_opts, :on_mount, [])
    host_session = Keyword.get(expanded_opts, :session, %{})

    unless is_map(host_session) do
      raise ArgumentError, "live_canvas :session must be a map"
    end

    session_name = Keyword.get(expanded_opts, :as, default_session_name(expanded_path))
    session = Map.put(host_session, "tc_base_path", expanded_path)

    quote do
      live_session unquote(session_name),
        on_mount: [{TimelessCanvas.Web.Hooks, :assign_config}] ++ unquote(on_mount_hooks),
        session: unquote(Macro.escape(session)) do
        live(unquote(expanded_path), TimelessCanvas.Web.CanvasListLive)
        live(unquote(expanded_path) <> "/:id", TimelessCanvas.Web.CanvasLive)
      end
    end
  end

  defp default_session_name(path) do
    suffix = path |> String.trim("/") |> String.replace(~r/[^a-zA-Z0-9_]+/, "_")
    String.to_atom("timeless_canvas_#{if suffix == "", do: "root", else: suffix}")
  end
end
