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
            spruce_goose: :permanent,
            task_host: :permanent,
            school_ops: :permanent,
            bizops_kb: :permanent
          ],
          # Inherited from spruce_goose's release: self-contained runtime and
          # unstripped beams (its provenance chunks must survive the build).
          include_erts: true,
          strip_beams: false
        ],
        # The ledger, the task host (sign-in, the task view, its API and the
        # change feed) and SpruceGoose (the CLI service, until it retires),
        # without dispatch, which cannot boot in production until its
        # integrations are configured (docs/deploy.md). Nothing here depends
        # on dispatch.
        orchestration: [
          applications: [
            biz_kit_cluster: :permanent,
            coop_substrate: :permanent,
            biz_kit_identity: :permanent,
            spruce_goose: :permanent,
            task_host: :permanent,
            school_ops: :permanent,
            bizops_kb: :permanent
          ],
          include_erts: true,
          strip_beams: false
        ],
        # The rebuilt eatsbot: the ledger that admits every order step and the
        # cash-only storefront and kitchen board (apps/restaurant_host).
        restaurant: [
          applications: [
            biz_kit_cluster: :permanent,
            coop_substrate: :permanent,
            restaurant_host: :permanent
          ],
          include_erts: true,
          strip_beams: false
        ],
        procurement: [
          applications: [
            biz_kit_cluster: :permanent,
            coop_substrate: :permanent,
            procurement_host: :permanent
          ],
          runtime_config_path: "config/procurement_runtime.exs",
          include_erts: true,
          strip_beams: false
        ]
      ]
    ]
  end
end
