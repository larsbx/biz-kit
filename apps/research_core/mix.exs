defmodule ResearchCore.MixProject do
  use Mix.Project

  def project do
    [
      app: :research_core,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: []
    ] ++ umbrella_paths()
  end

  def application, do: [extra_applications: []]

  defp umbrella_paths do
    if Path.basename(Path.dirname(__DIR__)) == "apps" and
         File.regular?(Path.expand("../../mix.exs", __DIR__)) and
         File.dir?(Path.expand("../../apps", __DIR__)) do
      [
        build_path: "../../_build",
        config_path: "../../config/config.exs",
        deps_path: "../../deps",
        lockfile: "../../mix.lock"
      ]
    else
      []
    end
  end
end
