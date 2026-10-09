defmodule Eatsbot.Extensions.Kafka.MixProject do
  use Mix.Project

  def project do
    [
      app: :eatsbot_extension_kafka,
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
      # Keep producer behavior on the existing line until the separate client spike.
      {:kafka_ex, "~> 0.14.0", runtime: false},
      {:eatsbot_core,
       path:
         Path.join(["..", "..", "core"])
         |> Path.expand()}
    ]
  end
end
