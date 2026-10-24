defmodule FulfillmentCore.MixProject do
  use Mix.Project

  def project do
    [
      app: :fulfillment_core,
      version: "0.1.0",
      elixir: "~> 1.19",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      deps: []
    ]
  end

  def application, do: [extra_applications: []]
end
