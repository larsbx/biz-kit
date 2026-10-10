# biz-kit architecture

The umbrella preserves each application's history and domain contracts. These
documents evaluate integration across those contracts; a recommendation is not
an authority transfer or permission to rewrite existing records.

- [Integration decision matrix and staged path — 2026-10-09](2026-10-09-integration-decisions.md):
  persistence, authentication, production isolation, Keel ownership, and optional
  applications, with implementation evidence and migration gates.

Application contracts remain under `apps/`. Start with
[CoopSubstrate's normative substrate](../../apps/coop_substrate/SUBSTRATE.md),
[SpruceGoose's authority planes](../../apps/spruce_goose/docs/authority-planes.md),
and its [documented current state](../../apps/spruce_goose/docs/current-state.md).
