defmodule Keel.MixProject do
  use Mix.Project

  def project do
    [
      app: :keel,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: false,
      deps: [{:stream_data, "~> 1.1", only: :test}]
    ]
  end

  def application, do: [extra_applications: []]
end
