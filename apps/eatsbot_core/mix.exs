defmodule EatsbotCore.MixProject do
  use Mix.Project

  def project do
    [
      app: :eatsbot_core,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      consolidate_protocols: Mix.env() != :dev,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ash_money, "~> 0.2.6"},
      {:commerce_core, in_umbrella: true},
      {:fulfillment_core, in_umbrella: true},
      {:igniter, "~> 0.5", only: [:dev, :test]},
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
      {:ash_authentication, "~> 5.0-rc"},
      {:ash_authentication_phoenix, "~> 3.0-rc"},
      {:ash_graphql, "~> 1.12.0"},
      {:ash_phoenix, "~> 2.3.25"},
      {:ash_postgres, "~> 2.15.1"},
      {:ash, "~> 3.37.0"},
      {:ash_admin, "~> 1.3.2"},
      {:ex_cldr, "~> 2.0"},
      {:ex_cldr_numbers, "~> 2.33"},
      {:ex_cldr_currencies, "~> 2.16"},
      {:ex_cldr_dates_times, "~> 2.20"},
      {:ex_cldr_calendars, "~> 2.4"},
      {:ex_cldr_lists, "~> 2.11"},
      {:ex_cldr_units, "~> 3.17"},
      {:gettext, "~> 1.0.2"},
      {:picosat_elixir, "~> 0.2.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
