import Config

# Library note: config files are NOT loaded when timeless_canvas is used as
# a dependency — this exists only for local dev/test tooling (the browser
# E2E asset bundle, see `mix e2e.assets`).
if config_env() in [:dev, :test] do
  config :esbuild,
    version: "0.25.4",
    e2e: [
      args:
        ~w(test/support/e2e/app.js --bundle --target=es2020 --outfile=priv/static-test/assets/app.js),
      cd: Path.expand("..", __DIR__),
      env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
    ]
end
