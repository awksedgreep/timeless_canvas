defmodule TimelessCanvas.MixProject do
  use Mix.Project

  @version "0.4.0"

  def project do
    [
      app: :timeless_canvas,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
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

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.8"},
      {:phoenix_ecto, "~> 4.5"},
      {:phoenix_live_view, "~> 1.1"},
      {:phoenix_html, "~> 4.1"},
      {:ecto_sql, "~> 3.13"},
      {:jason, "~> 1.2"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev, optional: true}
    ]
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
