defmodule BizKitComposition.MixProject do
  use Mix.Project

  def project do
    [
      app: :biz_kit_composition,
      version: "0.1.0",
      elixir: "~> 1.19",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      deps: [
        {:commerce_core, in_umbrella: true},
        {:group_buy_core, in_umbrella: true},
        {:inventory_core, in_umbrella: true},
        {:fulfillment_core, in_umbrella: true}
      ]
    ]
  end

  def application, do: [extra_applications: []]
end
