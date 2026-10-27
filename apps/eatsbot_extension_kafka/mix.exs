defmodule Eatsbot.Extensions.Kafka.MixProject do
  use Mix.Project

  def project do
    [
      app: :eatsbot_extension_kafka,
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
      extra_applications: [:logger, :ssl]
    ]
  end

  defp deps do
    [
      # The extension owns its explicit producer client; no default KafkaEx worker.
      {:kafka_ex, "~> 1.1.2", runtime: false},
      {:eatsbot_core, in_umbrella: true}
    ]
  end
end
