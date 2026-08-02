defmodule TimelessCanvas.Test.Auth do
  @moduledoc """
  Test auth hook: assigns `:current_user` from the session (put there by
  `TimelessCanvas.ConnCase.log_in_user/2`) or falls back to a default user.
  """

  import Phoenix.Component, only: [assign: 3]

  @default_user %{id: 1, username: "tester", email: "tester@example.com"}

  def default_user, do: @default_user

  def on_mount(:default, _params, session, socket) do
    user = session["current_user"] || @default_user
    {:cont, assign(socket, :current_user, user)}
  end
end

defmodule TimelessCanvas.Test.Router do
  @moduledoc false

  use Phoenix.Router

  import Plug.Conn
  import Phoenix.Controller
  import Phoenix.LiveView.Router
  import TimelessCanvas.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:protect_from_forgery)
    plug(:put_root_layout, html: {TimelessCanvas.Test.E2E.Layout, :root})
  end

  scope "/" do
    pipe_through(:browser)

    # Browser login for the E2E suite (harmless under LiveViewTest).
    get("/e2e/login", TimelessCanvas.Test.E2E.SessionController, :login)

    live_canvas("/canvas", on_mount: [{TimelessCanvas.Test.Auth, :default}])
  end
end

defmodule TimelessCanvas.Test.Endpoint do
  @moduledoc """
  Minimal endpoint for LiveViewTest. Runtime config is provided by
  `Application.put_env/3` in `test/test_helper.exs` before it is started.
  """

  use Phoenix.Endpoint, otp_app: :timeless_canvas

  @session_options [
    store: :cookie,
    key: "_timeless_canvas_test_key",
    signing_salt: "tc_session_salt",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  # E2E assets (JS bundle + stylesheet) built by `mix e2e.assets` into
  # priv/static-test/assets. Unused by LiveViewTest.
  plug(Plug.Static, at: "/e2e-assets", from: {:timeless_canvas, "priv/static-test/assets"})

  plug(Plug.Parsers, parsers: [:urlencoded], pass: ["*/*"])
  plug(Plug.Session, @session_options)
  plug(TimelessCanvas.Test.Router)
end
