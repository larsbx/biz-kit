defmodule CoopSubstrate.MixProject do
  use Mix.Project

  def project do
    [
      app: :coop_substrate,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
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
      # Canonical log per the AshEvents spike decision (SUBSTRATE.md §3):
      # the eventstore library only — Commanded aggregates are NOT adopted.
      {:eventstore, "~> 1.4"},
      {:jason, "~> 1.4"},
      {:stream_data, "~> 1.1", only: [:test, :dev]}
    ]
  end

  defp aliases do
    [
      test: ["event_store.create --quiet", "event_store.init --quiet", "test"]
    ]
  end
end
