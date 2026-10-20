defmodule TaskCore.MixProject do
  use Mix.Project

  # No dependencies, by design: a host application vendors this app (a git
  # or path dependency) and supplies its own storage, signing and transport.
  def project do
    [
      app: :task_core,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      test_ignore_filters: [~r|^test/fixtures/|],
      deps: []
    ]
  end

  def application, do: [extra_applications: []]
end
