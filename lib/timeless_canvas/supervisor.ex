defmodule TimelessCanvas.Supervisor do
  @moduledoc """
  Convenience supervisor that starts the DataSource.Manager, StreamManager,
  the editor presence tracker, and the per-canvas poller infrastructure
  (registry + dynamic supervisor).

  Add to your application's supervision tree (after your PubSub — the
  presence tracker connects to the pubsub configured under
  `config :timeless_canvas, pubsub: ...`):

      {TimelessCanvas.Supervisor, []}
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: TimelessCanvas.CanvasRegistry},
      {DynamicSupervisor, name: TimelessCanvas.PollerSupervisor, strategy: :one_for_one},
      TimelessCanvas.DataSource.Manager,
      TimelessCanvas.StreamManager,
      # Reads the consumer-configured pubsub at start, like everything else.
      {TimelessCanvas.Presence, pubsub_server: TimelessCanvas.pubsub()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
