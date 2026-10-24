defmodule SchoolOps.MixProject do
  use Mix.Project

  def project do
    [
      app: :school_ops,
      version: "0.1.0",
      elixir: "~> 1.19",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      deps: [{:task_core, in_umbrella: true}]
    ]
  end

  def application, do: [extra_applications: []]
end
