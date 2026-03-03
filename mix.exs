defmodule HashCluster.MixProject do
  use Mix.Project

  def project do
    [
      app: :hash_cluster,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {HashCluster.Application, []},
      extra_applications: [:logger, :runtime_tools, :mnesia, :crypto]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 0.20"},
      {:phoenix_html, "~> 4.0"},
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
      {:bandit, "~> 1.2"},
      {:jason, "~> 1.4"},
      {:gettext, "~> 0.24"},
      {:floki, ">= 0.30.0", only: :test}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "assets.build"],
      "assets.build": ["esbuild default"],
      "assets.deploy": ["esbuild default --minify"]
    ]
  end
end
