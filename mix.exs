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
            biz_kit_cluster: :permanent,
            coop_substrate: :permanent,
            biz_kit_identity: :permanent,
            dispatch: :permanent,
            spruce_goose: :permanent
          ],
          # Inherited from spruce_goose's release: self-contained runtime and
          # unstripped beams (its provenance chunks must survive the build).
          include_erts: true,
          strip_beams: false
        ]
      ]
    ]
  end
end
