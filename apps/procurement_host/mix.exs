defmodule ProcurementHost.MixProject do
  use Mix.Project
  def project do
    [app: :procurement_host, version: "0.1.0", elixir: "~> 1.19",
     build_path: "../../_build", config_path: "../../config/config.exs",
     deps_path: "../../deps", lockfile: "../../mix.lock",
     start_permanent: Mix.env() == :prod,
     deps: [{:commerce_core, in_umbrella: true}, {:coop_substrate, in_umbrella: true}, {:plug, "~> 1.18"}, {:bandit, "~> 1.14"}]]
  end
  def application, do: [extra_applications: [:logger, :crypto], mod: {ProcurementHost.Application, []}]
end
