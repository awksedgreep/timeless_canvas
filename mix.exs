defmodule TimelessCanvas.MixProject do
  use Mix.Project

  @version "0.4.13"

  def project do
    [
      app: :timeless_canvas,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      name: "TimelessCanvas",
      description: "Embeddable canvas editor for Phoenix LiveView applications",
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  def cli do
    [preferred_envs: ["test.e2e": :test, "e2e.assets": :test]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:floki, ">= 0.30.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:iconify_ex, "~> 0.7"},
      {:phoenix, "~> 1.8"},
      {:phoenix_ecto, "~> 4.5"},
      {:phoenix_live_view, "~> 1.1"},
      {:phoenix_html, "~> 4.1"},
      {:ecto_sql, "~> 3.13"},
      {:jason, "~> 1.2"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev, optional: true},
      # Browser E2E suite only: HTTP server for the test endpoint.
      {:bandit, "~> 1.0", only: :test}
    ]
  end

  defp aliases do
    [
      "e2e.assets": &build_e2e_assets/1,
      "test.e2e": &run_e2e_tests/1
    ]
  end

  # Build the browser bundle (hooks + LiveSocket) and stylesheet the E2E
  # suite serves from the test endpoint. Output is gitignored.
  defp build_e2e_assets(_args) do
    Mix.Task.run("esbuild", ["e2e"])
    File.mkdir_p!("priv/static-test/assets")
    File.cp!("assets/css/timeless_canvas.css", "priv/static-test/assets/timeless_canvas.css")
  end

  # Run only the browser E2E tests (tagged :e2e; excluded from plain
  # `mix test`). E2E=1 makes test_helper.exs boot the endpoint with a real
  # HTTP server and fast poll/autosave timers.
  defp run_e2e_tests(args) do
    System.put_env("E2E", "1")
    build_e2e_assets([])
    Mix.Task.run("test", ["--only", "e2e" | args])
  end

  defp package do
    [
      maintainers: ["Mark Cotner"],
      licenses: ["MIT"],
      links: %{},
      files: ~w(lib assets priv mix.exs README.md LICENSE)
    ]
  end
end
