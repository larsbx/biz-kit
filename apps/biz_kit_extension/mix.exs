defmodule BizKit.Extension.MixProject do
  use Mix.Project

  def project do
    [
      app: :biz_kit_extension,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: []
    ] ++ umbrella_paths()
  end

  def application, do: [extra_applications: []]

  # This policy package must also compile outside the umbrella.
  defp umbrella_paths do
    if Path.basename(Path.dirname(__DIR__)) == "apps" and
         File.regular?(Path.expand("../../mix.exs", __DIR__)) and
         File.dir?(Path.expand("../../apps", __DIR__)) do
      [
        build_path: "../../_build",
        config_path: "../../config/config.exs",
        deps_path: "../../deps",
        lockfile: "../../mix.lock"
      ]
    else
      []
    end
  end
end
