defmodule Eatsbot.Extensions.Prometheus.MixProject do
  use Mix.Project

  def project do
    [
      app: :eatsbot_extension_prometheus,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      # The application and its path dependencies resolve one shared security lock.
      lockfile: Path.expand("../../mix.lock", __DIR__),
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
      {:phoenix, "~> 1.7.24"},
      {:prom_ex, "~> 1.11.0"},
      {:eatsbot_core,
       path:
         Path.join(["..", "..", "core"])
         |> Path.expand()}
    ]
  end
end
