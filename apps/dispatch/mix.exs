defmodule Dispatch.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :dispatch,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      version: @version,
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      consolidate_protocols: Mix.env() != :dev,
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts",
        flags: [:error_handling, :extra_return, :missing_return, :unmatched_returns]
      ],
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.html": :test,
        "test.integration": :test
      ]
    ]
  end

  def application do
    [
      mod: {Dispatch.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Domain, persistence, and authorization (Section 19.1).
      {:ash, "~> 3.0"},
      {:ash_postgres, "~> 2.10"},
      {:ash_phoenix, "~> 2.0"},
      {:ash_authentication, "~> 5.0-rc"},
      {:ash_oban, "~> 0.4"},
      {:ash_state_machine, "~> 0.2"},
      {:ash_cloak, "~> 0.1"},
      {:ecto_sql, "~> 3.12"},
      {:postgrex, "~> 0.19"},
      {:geo_postgis, "~> 3.7"},
      {:oban, "~> 2.19"},
      {:picosat_elixir, "~> 0.2"},

      # HTTP, portal, and the canonical OpenAPI 3.1 description.
      {:phoenix, "~> 1.8"},
      {:phoenix_html, "~> 4.1"},
      {:bandit, "~> 1.12"},
      {:open_api_spex, "~> 3.21"},
      {:jason, "~> 1.4"},

      # Outbound HTTP, used directly for OIDC key discovery (Section 23.1).
      # Declared here rather than relied on transitively: the TLS trust store
      # below is what makes token verification sound.
      {:finch, "~> 0.19"},
      {:castore, "~> 1.0"},

      # Observability (Section 32).
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.1"},

      # Tooling: the format, lint, typecheck, and dependency-audit CI gates.
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.1"},
      {:excoveralls, "~> 0.18", only: :test},
      {:phoenix_live_reload, "~> 1.5", only: :dev}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ash.setup"],
      # `mix test` stays unaliased so it behaves as contributors expect. The
      # integration tag is excluded in test_helper.exs, so the unit gate needs no
      # database; the integration gate opts back in and creates one first.
      "test.integration": ["ash.setup --quiet", "test --only integration"],
      # Section 20: contracts/openapi.json is generated and diff-checked.
      "openapi.generate": ["run --no-start priv/tasks/openapi_generate.exs"],
      "openapi.check": ["run --no-start priv/tasks/openapi_check.exs"]
    ]
  end
end
