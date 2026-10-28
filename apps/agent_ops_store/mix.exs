defmodule AgentOpsStore.MixProject do
  use Mix.Project

  def project do
    [
      app: :agent_ops_store,
      version: "0.1.0",
      elixir: "~> 1.19",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      deps: [
        {:agent_core, in_umbrella: true},
        {:task_core, in_umbrella: true},
        {:postgrex, "~> 0.22"},
        {:jason, "~> 1.4"}
      ]
    ]
  end

  def application, do: [extra_applications: [:crypto]]
end
