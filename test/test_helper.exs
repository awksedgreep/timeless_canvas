# E2E=1 (set by `mix test.e2e`) boots the endpoint with a real HTTP server
# on a random port and shortens every background timer so browser flows
# observe poll/autosave effects quickly. Plain `mix test` stays browserless.
e2e? = System.get_env("E2E") == "1"

# Library-level configuration consumed by TimelessCanvas config accessors.
Application.put_env(:timeless_canvas, :pubsub, TimelessCanvas.TestPubSub)
Application.put_env(:timeless_canvas, :persistence, TimelessCanvas.Test.FakePersistence)
Application.put_env(:timeless_canvas, :auth, TimelessCanvas.Auth.Noop)

Application.put_env(:timeless_canvas, :data_source,
  module: TimelessCanvas.Test.FakeDataSource,
  config: %{},
  # Effectively disable background polling / graph refresh during unit
  # tests; the E2E suite needs real (fast) poll ticks.
  poll_interval: if(e2e?, do: 300, else: 3_600_000)
)

if e2e? do
  Application.put_env(:timeless_canvas, :autosave_ms, 200)
  Application.put_env(:timeless_canvas, :autosave_retry_ms, 500)
  Application.put_env(:timeless_canvas, :stream_batch_ms, 50)
end

# Endpoint runtime config must exist before the endpoint starts.
Application.put_env(:timeless_canvas, TimelessCanvas.Test.Endpoint,
  secret_key_base: String.duplicate("timeless_canvas_secret_", 3),
  live_view: [signing_salt: "tc_lv_salt"],
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {127, 0, 0, 1}, port: 0],
  check_origin: false,
  # Browsers request /favicon.ico etc.; render 404s via a real module
  # instead of the default (nonexistent) ErrorView.
  render_errors: [formats: [html: TimelessCanvas.Test.ErrorHTML], layout: false],
  server: e2e?
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

ExUnit.start(exclude: if(e2e?, do: [], else: [:e2e]))
