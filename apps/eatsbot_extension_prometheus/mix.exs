defmodule Eatsbot.Extensions.Prometheus.MixProject do
  use Mix.Project

  def project do
    [
      app: :eatsbot_extension_prometheus,
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
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:phoenix, "~> 1.8"},
      {:prom_ex, "~> 1.11.0"},
      {:eatsbot_core, in_umbrella: true}
    ]
  end
end
