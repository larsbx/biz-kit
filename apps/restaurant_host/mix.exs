defmodule RestaurantHost.MixProject do
  use Mix.Project

  def project do
    [
      app: :restaurant_host,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [extra_applications: [:logger], mod: {RestaurantHost.Application, []}]
  end

  defp deps do
    [
      # The rebuilt eatsbot's rules: the kitchen workflow and signed admission.
      {:restaurant_core, in_umbrella: true},
      # Menu, pricing and tax: the device prices an order before signing it.
      {:commerce_core, in_umbrella: true},
      # The signed Log every order step is admitted through.
      {:coop_substrate, in_umbrella: true},
      {:phoenix, "~> 1.8"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_view, "~> 1.2.12"},
      {:bandit, "~> 1.14"},
      {:jason, "~> 1.4"},
      {:lazy_html, "~> 0.1.13", only: :test}
    ]
  end
end
