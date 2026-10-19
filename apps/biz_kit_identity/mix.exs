defmodule BizKit.Identity.MixProject do
  use Mix.Project

  def project do
    [
      app: :biz_kit_identity,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto], mod: {BizKit.Identity.Application, []}]
  end

  defp deps do
    [
      {:biz_kit_cluster, in_umbrella: true},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:plug, "~> 1.16", only: :test}
    ]
  end
end
