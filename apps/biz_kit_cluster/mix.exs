defmodule BizKit.Cluster.MixProject do
  use Mix.Project

  def project do
    [
      app: :biz_kit_cluster,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]),
      deps: []
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {BizKit.Cluster.Application, []}]
  end
end
