defmodule Eatsbot.MixProject do
  use Mix.Project

  def project do
    [
      app: :eatsbot,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      version: "1.0.41",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      consolidate_protocols: Mix.env() != :dev,
      aliases: aliases(),
      deps: deps(),
      preferred_cli_env: [
        "test.watch": :test
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Eatsbot.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:ash_authentication, "~> 5.0-rc"},
      {:ash_authentication_phoenix, "~> 3.0-rc"},
      {:ash_graphql, "~> 1.12.0"},
      {:ash_phoenix, "~> 2.3.25"},
      {:ash_postgres, "~> 2.15.1"},
      {:ash, "~> 3.37.0"},
      {:igniter, "~> 0.5", only: [:dev, :test]},
      {:phoenix, "~> 1.8"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.10"},
      {:postgrex, "~> 0.22.4"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.12"},
      {:floki, ">= 0.30.0", only: :test},
      {:lazy_html, "~> 0.1.13", only: :test},
      {:phoenix_live_dashboard, "~> 0.9.1"},
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.2", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.5"},
      {:finch, "~> 0.13"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.3.1"},
      {:bandit, "~> 1.13.1"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.36", only: [:dev, :test], runtime: false},
      {:opentelemetry_exporter, "~> 1.8.0"},
      {:opentelemetry, "~> 1.5.0"},
      {:opentelemetry_api, "~> 1.4.0"},
      {:opentelemetry_ecto, "~> 1.2.0"},
      {:opentelemetry_phoenix, "~> 2.0.0"},
      {:opentelemetry_bandit, "~> 0.3.0"},
      {:opentelemetry_ash, "~> 0.1.0"},
      {:picosat_elixir, "~> 0.2.0"},
      {:mix_test_watch, "~> 1.0", only: [:dev, :test], runtime: false},
      {:ash_admin, "~> 1.3.2"},
      {:plug, "~> 1.20.3"},
      {:friendlyid, "~> 0.2.0"},
      {:req, "~> 0.7.5"},
      {:ex_money_sql, "~> 2.1.0"},
      {:ash_money, "~> 0.2.6"},
      # {:ash_double_entry, "~> 1.0.12"},
      # Optional Enable Telegram Bot
      {:eatsbot_extension_telegram_bot, in_umbrella: true},
      {:eatsbot_extension_prometheus, in_umbrella: true},
      {:eatsbot_extension_kafka, in_umbrella: true},
      {:eatsbot_core, in_umbrella: true}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: [
        "deps.get",
        "localize.download_locales",
        "ash.setup",
        "assets.setup",
        "assets.build",
        "run priv/repo/seeds.exs"
      ],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ash.setup --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["tailwind eatsbot", "esbuild eatsbot"],
      "assets.deploy": [
        "tailwind eatsbot --minify",
        "esbuild eatsbot --minify",
        "phx.digest"
      ]
    ]
  end
end
