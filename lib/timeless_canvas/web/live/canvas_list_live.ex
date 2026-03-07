defmodule TimelessCanvas.Web.CanvasListLive do
  use TimelessCanvas.Web, :live_view

  defp persistence, do: TimelessCanvas.persistence()
  defp auth, do: TimelessCanvas.auth()

  @impl true
  def mount(_params, _session, socket) do
    current_user = TimelessCanvas.current_user(socket)
    canvases = persistence().list_accessible_canvases(current_user)

    {:ok,
     assign(socket,
       canvases: canvases,
       current_user: current_user,
       is_admin: auth().admin?(current_user),
       editing_id: nil,
       page_title: "My Canvases"
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto p-8">
      <div class="flex items-center justify-between mb-8">
        <h1 class="text-2xl font-bold">
          My Canvases <span :if={@is_admin} class="badge badge-primary ml-2">Admin</span>
        </h1>
        <button phx-click="new_canvas" class="btn btn-primary">
          New Canvas
        </button>
      </div>

      <div :if={@canvases == []} class="text-center text-base-content/60 py-16">
        <p class="text-lg mb-4">No canvases yet</p>
        <p>Click "New Canvas" to create your first canvas.</p>
      </div>

      <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
        <div :for={canvas <- @canvases} class="card bg-base-200 shadow-sm">
          <div class="card-body">
            <h2 class="card-title">
              <form
                :if={@editing_id == canvas.id}
                phx-submit="save_rename"
                phx-click-away="cancel_rename"
                class="flex-1"
              >
                <input type="hidden" name="canvas_id" value={canvas.id} />
                <input
                  type="text"
                  name="name"
                  value={canvas.name}
                  class="input input-sm input-bordered w-full"
                  autofocus
                  phx-key="Escape"
                  phx-keydown="cancel_rename"
                />
              </form>
              <.link
                :if={@editing_id != canvas.id}
                navigate={"#{@tc_base_path}/#{canvas.id}"}
                class="hover:underline"
              >
                {canvas.name}
              </.link>
              <span :if={canvas.parent_id} class="badge badge-sm badge-ghost ml-1">
                sub-canvas
              </span>
            </h2>
            <p class="text-sm text-base-content/60">
              Updated {Calendar.strftime(canvas.updated_at, "%b %d, %Y %H:%M")}
            </p>
            <div class="card-actions justify-end mt-2">
              <.link navigate={"#{@tc_base_path}/#{canvas.id}"} class="btn btn-sm btn-primary">
                Open
              </.link>
              <button
                :if={canvas.user_id == @current_user.id && @editing_id != canvas.id}
                phx-click="start_rename"
                phx-value-id={canvas.id}
                class="btn btn-sm btn-ghost"
              >
                Rename
              </button>
              <button
                :if={canvas.user_id == @current_user.id}
                phx-click="delete_canvas"
                phx-value-id={canvas.id}
                data-confirm="Delete this canvas? This cannot be undone."
                class="btn btn-sm btn-error btn-outline"
              >
                Delete
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("new_canvas", _params, socket) do
    user = socket.assigns.current_user
    existing_count = length(socket.assigns.canvases)
    name = "New Canvas #{existing_count + 1}"

    case persistence().create_canvas(user.id, name) do
      {:ok, canvas} ->
        {:noreply, redirect(socket, to: "#{socket.assigns.tc_base_path}/#{canvas.id}")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not create canvas")}
    end
  end

  def handle_event("start_rename", %{"id" => id_str}, socket) do
    {id, ""} = Integer.parse(id_str)
    {:noreply, assign(socket, editing_id: id)}
  end

  def handle_event("cancel_rename", _params, socket) do
    {:noreply, assign(socket, editing_id: nil)}
  end

  def handle_event("save_rename", %{"canvas_id" => id_str, "name" => name}, socket) do
    user = socket.assigns.current_user
    {id, ""} = Integer.parse(id_str)
    name = String.trim(name)

    if name == "" do
      {:noreply, assign(socket, editing_id: nil)}
    else
      case persistence().rename_canvas(id, user.id, name) do
        {:ok, _} ->
          canvases = persistence().list_accessible_canvases(user)
          {:noreply, assign(socket, canvases: canvases, editing_id: nil)}

        {:error, _} ->
          {:noreply,
           socket
           |> put_flash(:error, "Could not rename canvas")
           |> assign(editing_id: nil)}
      end
    end
  end

  def handle_event("delete_canvas", %{"id" => id_str}, socket) do
    user = socket.assigns.current_user
    {id, ""} = Integer.parse(id_str)

    case persistence().delete_canvas(id, user.id) do
      {:ok, _} ->
        canvases = persistence().list_accessible_canvases(user)
        {:noreply, assign(socket, canvases: canvases)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not delete canvas")}
    end
  end
end
