defmodule CoopSubstrate.MixProject do
  use Mix.Project

  def project do
    [
      app: :coop_substrate,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {CoopSubstrate.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:rustler, "~> 0.36"},
      {:cbor, "~> 1.0"},
      {:stream_data, "~> 1.1", only: [:test, :dev]}
      # Event store dep added after the AshEvents spike decision (see SUBSTRATE.md).
    ]
  end
end
