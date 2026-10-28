defmodule HawalaCapability.MixProject do
  use Mix.Project

  def project do
    [
      app: :hawala_capability,
      version: "0.1.0",
      elixir: ">= 1.14.0 and < 2.0.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixirc_paths: if(Mix.env() == :test, do: ["test/support"], else: []),
      deps: []
    ]
  end

  def application, do: [extra_applications: [:crypto]]
end
