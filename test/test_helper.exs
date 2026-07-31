# Library-level configuration consumed by TimelessCanvas config accessors.
Application.put_env(:timeless_canvas, :pubsub, TimelessCanvas.TestPubSub)
Application.put_env(:timeless_canvas, :persistence, TimelessCanvas.Test.FakePersistence)
Application.put_env(:timeless_canvas, :auth, TimelessCanvas.Auth.Noop)

Application.put_env(:timeless_canvas, :data_source,
  module: TimelessCanvas.Test.FakeDataSource,
  config: %{},
  # Effectively disable background polling / graph refresh during tests.
  poll_interval: 3_600_000
)

# Endpoint runtime config must exist before the endpoint starts.
Application.put_env(:timeless_canvas, TimelessCanvas.Test.Endpoint,
  secret_key_base: String.duplicate("timeless_canvas_secret_", 3),
  live_view: [signing_salt: "tc_lv_salt"],
  server: false
)

Logger.configure(level: :warning)

# iconify_ex cannot generate icons without npm assets; use pre-seeded
# placeholders in a temp directory instead (see TimelessCanvas.Test.Icons).
TimelessCanvas.Test.Icons.ensure_placeholders!()

TimelessCanvas.Test.FakeDataSource.ensure_table!()

{:ok, _} =
  Supervisor.start_link(
    [
      {Phoenix.PubSub, name: TimelessCanvas.TestPubSub},
      TimelessCanvas.Test.FakePersistence,
      TimelessCanvas.Supervisor,
      TimelessCanvas.Test.Endpoint
    ],
    strategy: :one_for_one,
    name: TimelessCanvas.TestSupervisor
  )

ExUnit.start()
