defmodule TaskCore.MixProject do
  use Mix.Project

  # No dependencies, by design: a host application vendors this app (a git
  # or path dependency) and supplies its own storage, signing and transport.
  def project do
    [
      app: :task_core,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      test_ignore_filters: [~r|^test/fixtures/|],
      deps: []
    ] ++ umbrella_paths()
  end

  # In the biz-kit umbrella all apps share one _build, deps, config and lock.
  # A source package copied or fetched into an unrelated Mix host must not
  # refer to ../../mix.lock or another project's config/dependency directory.
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

  def application, do: [extra_applications: []]
end
