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
  end

  scope "/" do
    pipe_through(:browser)

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

  plug(Plug.Session, @session_options)
  plug(TimelessCanvas.Test.Router)
end
