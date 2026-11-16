defmodule ScfHost.MixProject do
  use Mix.Project

  def project do
    [
      app: :scf_host,
      version: "0.1.0",
      elixir: "~> 1.19",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      start_permanent: Mix.env() == :prod,
      deps: [
        # The SCF rulebook the Log applies at admission, and the statements.
        {:scf_core, in_umbrella: true},
        # The signed Log every écriture is admitted through.
        {:coop_substrate, in_umbrella: true},
        {:plug, "~> 1.18"},
        {:bandit, "~> 1.14"},
        {:jason, "~> 1.4"}
      ]
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto], mod: {ScfHost.Application, []}]
end
