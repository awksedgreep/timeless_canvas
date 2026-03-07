defmodule TimelessCanvas.Supervisor do
  @moduledoc """
  Convenience supervisor that starts the DataSource.Manager and StreamManager.

  Add to your application's supervision tree:

      {TimelessCanvas.Supervisor, []}
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      TimelessCanvas.DataSource.Manager,
      TimelessCanvas.StreamManager
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
