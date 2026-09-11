defmodule TimelessCanvas.Web.CanvasShareComponent do
  use TimelessCanvas.Web, :live_component

  defp persistence, do: TimelessCanvas.persistence()
  defp auth, do: TimelessCanvas.auth()

  @impl true
  def update(assigns, socket) do
    accesses = persistence().list_access(assigns.canvas_id)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(
       accesses: accesses,
       username: "",
       role: "editor",
       error: nil
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="canvas-share-panel">
      <div class="flex items-center justify-between mb-4">
        <h3 class="text-lg font-semibold">Share Canvas</h3>
        <button phx-click="close_share" class="btn btn-sm btn-ghost">
          &times;
        </button>
      </div>

      <form phx-submit="grant" phx-target={@myself} class="flex gap-2 mb-4">
        <input
          type="text"
          name="username"
          value={@username}
          placeholder="username"
          class="input input-bordered flex-1"
          required
        />
        <select name="role" class="select select-bordered">
          <option value="editor" selected={@role == "editor"}>Editor</option>
          <option value="viewer" selected={@role == "viewer"}>Viewer</option>
        </select>
        <button type="submit" class="btn btn-primary btn-sm">Share</button>
      </form>

      <p :if={@error} class="text-error text-sm mb-2">{@error}</p>

      <div :if={@accesses == []} class="text-base-content/60 text-sm">
        Not shared with anyone yet.
      </div>

      <div
        :for={access <- @accesses}
        class="flex items-center justify-between py-2 border-b border-base-300"
      >
        <div>
          <span class="font-medium">{access.user.username}</span>
          <span class={"badge badge-sm ml-2 #{role_badge_class(access.role)}"}>
            {access.role}
          </span>
        </div>
        <button
          phx-click="revoke"
          phx-value-user-id={access.user_id}
          phx-target={@myself}
          data-confirm={"Remove #{access.user.username}'s access to this canvas?"}
          class="btn btn-xs btn-error btn-outline"
        >
          Remove
        </button>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("grant", %{"username" => username, "role" => role}, socket) do
    with :ok <- authorize_share(socket),
         {:ok, role_atom} <- share_role(role),
         user when not is_nil(user) <- persistence().lookup_user_by_username(username),
         {:ok, _} <- persistence().grant_access(socket.assigns.canvas_id, user.id, role_atom) do
      accesses = persistence().list_access(socket.assigns.canvas_id)
      {:noreply, assign(socket, accesses: accesses, username: "", error: nil)}
    else
      {:error, :unauthorized} ->
        {:noreply, assign(socket, error: "Not authorized to share this canvas")}

      {:error, :invalid_role} ->
        {:noreply, assign(socket, error: "Invalid sharing role")}

      nil ->
        {:noreply, assign(socket, error: "No user found with that username")}

      {:error, _} ->
        {:noreply, assign(socket, error: "Could not grant access")}
    end
  end

  def handle_event("revoke", %{"user-id" => user_id_str}, socket) do
    with :ok <- authorize_share(socket),
         {user_id, ""} <- Integer.parse(user_id_str),
         {:ok, _} <- persistence().revoke_access(socket.assigns.canvas_id, user_id) do
      accesses = persistence().list_access(socket.assigns.canvas_id)
      {:noreply, assign(socket, accesses: accesses, error: nil)}
    else
      {:error, :unauthorized} ->
        {:noreply, assign(socket, error: "Not authorized to share this canvas")}

      _ ->
        {:noreply, assign(socket, error: "Could not revoke access")}
    end
  end

  defp authorize_share(socket) do
    with %{current_user: current_user} <- socket.assigns,
         {:ok, canvas} <- persistence().get_canvas(socket.assigns.canvas_id) do
      auth().authorize(current_user, canvas, :share)
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp share_role("editor"), do: {:ok, :editor}
  defp share_role("viewer"), do: {:ok, :viewer}
  defp share_role(_), do: {:error, :invalid_role}

  defp role_badge_class(:editor), do: "badge-info"
  defp role_badge_class(:viewer), do: "badge-warning"
  defp role_badge_class(_), do: ""
end
