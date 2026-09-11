defmodule TimelessCanvas do
  @moduledoc """
  Embeddable canvas editor for Phoenix LiveView applications.

  ## Configuration

      config :timeless_canvas,
        repo: MyApp.Repo,
        pubsub: MyApp.PubSub,
        user_schema: MyApp.Accounts.User,
        persistence: TimelessCanvas.Persistence.Ecto,
        auth: TimelessCanvas.Auth.Noop,
        data_source: [module: TimelessCanvas.DataSource.Stub],
        stream_backends: [log: nil, trace: nil]
  """

  @doc "Returns the configured Ecto repo."
  def repo do
    required_config!(:repo, "an Ecto.Repo module")
  end

  @doc "Returns the configured PubSub module."
  def pubsub do
    required_config!(:pubsub, "a Phoenix.PubSub server name")
  end

  @doc "Returns the configured user schema module."
  def user_schema do
    Application.get_env(:timeless_canvas, :user_schema)
  end

  @doc "Returns the configured persistence module."
  def persistence do
    Application.get_env(:timeless_canvas, :persistence, TimelessCanvas.Persistence.Ecto)
  end

  @doc "Returns the configured auth module."
  def auth do
    Application.get_env(:timeless_canvas, :auth, TimelessCanvas.Auth.Noop)
  end

  @doc "Returns the configured data source options."
  def data_source_config do
    Application.get_env(:timeless_canvas, :data_source, [])
  end

  @doc "Returns the configured stream backends."
  def stream_backends do
    Application.get_env(:timeless_canvas, :stream_backends, [])
  end

  @doc """
  Extracts the current user from a socket or conn.

  Configure with:

      config :timeless_canvas, :current_user_fn, fn socket -> socket.assigns.current_user end

  Defaults to `socket.assigns[:current_user]`.
  """
  def current_user(socket_or_conn) do
    case Application.get_env(:timeless_canvas, :current_user_fn) do
      nil -> default_current_user(socket_or_conn)
      fun when is_function(fun, 1) -> fun.(socket_or_conn)
    end
  end

  defp default_current_user(%{assigns: assigns}) when is_map(assigns),
    do: Map.get(assigns, :current_user)

  defp default_current_user(_socket_or_conn), do: nil

  defp required_config!(key, expected) do
    case Application.fetch_env(:timeless_canvas, key) do
      {:ok, value} ->
        value

      :error ->
        raise ArgumentError,
              "missing config :timeless_canvas, #{inspect(key)} (expected #{expected})"
    end
  end
end
