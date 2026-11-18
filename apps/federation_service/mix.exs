defmodule FederationService.MixProject do
  use Mix.Project

  def project do
    [
      app: :federation_service,
      version: "0.1.0",
      test_ignore_filters: [~r/\/support\//],
      elixir: "~> 1.19",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      deps: [
        {:federation_core, in_umbrella: true},
        {:jason, "~> 1.4"},
        {:plug, "~> 1.18"},
        {:bandit, "~> 1.14.1"}
      ]
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto, :public_key, :ssl]]
end
