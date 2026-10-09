defmodule BizKit.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: [],
      releases: [
        biz_kit: [
          applications: [
            keel: :permanent,
            coop_substrate: :permanent,
            dispatch: :permanent,
            spruce_goose: :permanent
          ]
        ]
      ]
    ]
  end
end
