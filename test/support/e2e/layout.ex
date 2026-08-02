defmodule TimelessCanvas.Test.E2E.Layout do
  @moduledoc """
  Root layout for the test endpoint.

  LiveViewTest ignores everything here; the browser E2E suite needs the
  document shell to load the bundled JS (hooks + LiveSocket) and the
  library stylesheet, both served from `priv/static-test/assets` (built
  by `mix e2e.assets`).
  """

  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>TimelessCanvas E2E</title>
        <link rel="stylesheet" href="/e2e-assets/timeless_canvas.css" />
        <script defer src="/e2e-assets/app.js">
        </script>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end
end

defmodule TimelessCanvas.Test.E2E.SessionController do
  @moduledoc """
  Browser login endpoint for the E2E suite.

  A real browser cannot use `Plug.Test.init_test_session/2`, so the E2E
  ExUnit case serializes the user map into a token
  (`Base.url_encode64(:erlang.term_to_binary(user))`), and the browser
  visits `/e2e/login?token=...&to=/canvas/1`. The user lands in the
  session under `"current_user"` — the same key `TimelessCanvas.Test.Auth`
  reads on mount.
  """

  use Phoenix.Controller, formats: []

  def login(conn, %{"token" => token} = params) do
    user =
      token
      |> Base.url_decode64!()
      |> :erlang.binary_to_term([:safe])

    conn
    |> Plug.Conn.put_session("current_user", user)
    |> redirect(to: Map.get(params, "to", "/canvas"))
  end
end
