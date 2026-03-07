defmodule TimelessCanvas.Web.Hooks do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  def on_mount(:assign_config, _params, session, socket) do
    base_path = session["tc_base_path"] || "/canvas"
    {:cont, assign(socket, :tc_base_path, base_path)}
  end
end
