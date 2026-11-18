defmodule TaskHost.MixProject do
  use Mix.Project

  def project do
    [
      app: :task_host,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [extra_applications: [:logger], mod: {TaskHost.Application, []}]
  end

  # Tests start the host's own application tree (test_helper.exs). A plain
  # `mix test` would also start every dependency's test dependencies, among
  # them Localize, which reads eatsbot's shared configuration and does not
  # start without eatsbot.
  defp aliases, do: [test: "test --no-start"]

  defp deps do
    [
      # The signed Log every command, grant and feed frame goes through.
      {:coop_substrate, in_umbrella: true},
      # Task rules and projections the web view reads.
      {:task_core, in_umbrella: true},
      # Sign-in, sessions and their Postgres store.
      {:biz_kit_identity, in_umbrella: true},
      # Rate-limit counts are one per cluster.
      {:biz_kit_cluster, in_umbrella: true},
      {:phoenix, "~> 1.8"},
      {:bandit, "~> 1.12"},
      {:jason, "~> 1.4"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:req, "~> 0.5"}
    ]
  end
end
