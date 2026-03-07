defmodule TimelessCanvas.Web.AssetsController do
  @moduledoc false
  use Phoenix.Controller, formats: [:html]

  def css(conn, _params) do
    path = Application.app_dir(:timeless_canvas, "priv/static/timeless_canvas.css")

    conn
    |> put_resp_content_type("text/css")
    |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
    |> send_file(200, path)
  end
end
