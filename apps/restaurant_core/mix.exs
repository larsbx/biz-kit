defmodule RestaurantCore.MixProject do
  use Mix.Project

  def project do
    [
      app: :restaurant_core,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [{:commerce_core, in_umbrella: true}, {:stream_data, "~> 1.1", only: :test}]
    ] ++ umbrella_paths()
  end

  # In the biz-kit umbrella all apps share one _build, deps, config and lock.
  # A source package copied or fetched into an unrelated Mix host must not
  # refer to ../../mix.lock or another project's config/dependency directory.
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

  def application, do: [extra_applications: []]
end
