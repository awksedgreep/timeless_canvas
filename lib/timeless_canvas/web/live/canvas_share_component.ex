defmodule TimelessCanvas.Web.CanvasShareComponent do
  use TimelessCanvas.Web, :live_component

  defp persistence, do: TimelessCanvas.persistence()

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
    canvas_id = socket.assigns.canvas_id

    case persistence().lookup_user_by_username(username) do
      nil ->
        {:noreply, assign(socket, error: "No user found with that username")}

      user ->
        role_atom = String.to_existing_atom(role)

        case persistence().grant_access(canvas_id, user.id, role_atom) do
          {:ok, _} ->
            accesses = persistence().list_access(canvas_id)
            {:noreply, assign(socket, accesses: accesses, username: "", error: nil)}

          {:error, _} ->
            {:noreply, assign(socket, error: "Could not grant access")}
        end
    end
  end

  def handle_event("revoke", %{"user-id" => user_id_str}, socket) do
    canvas_id = socket.assigns.canvas_id
    {user_id, ""} = Integer.parse(user_id_str)

    case persistence().revoke_access(canvas_id, user_id) do
      {:ok, _} ->
        accesses = persistence().list_access(canvas_id)
        {:noreply, assign(socket, accesses: accesses)}

      {:error, _} ->
        {:noreply, assign(socket, error: "Could not revoke access")}
    end
  end

  defp role_badge_class(:editor), do: "badge-info"
  defp role_badge_class(:viewer), do: "badge-warning"
  defp role_badge_class(_), do: ""
end
