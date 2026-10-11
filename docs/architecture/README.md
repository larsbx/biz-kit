# biz-kit architecture

The consolidation target is one signed business-event ledger and rebuildable
domain views. The imported histories and existing identifiers remain intact.

- [One source of truth — 2026-10-11](2026-10-11-single-source-of-truth.md): current
  direction, common command/write path, removal targets, and cutover proof.
- [Integration comparison — 2026-10-09](2026-10-09-integration-decisions.md):
  baseline implementation evidence and tradeoffs. Its recommendation to retain
  independent authorities is superseded by the consolidation target.

- [First common-ledger task command](2026-10-11-first-ledger-task-command.md): notes
  retirement, signed baseline and scoped grant, append-time proposal admission,
  retry/replay contract, verification, and the next production cutover boundary.

Application contracts remain under `apps/`. Start with
[CoopSubstrate's normative substrate](../../apps/coop_substrate/SUBSTRATE.md),
[SpruceGoose's authority planes](../../apps/spruce_goose/docs/authority-planes.md),
and its [documented current state](../../apps/spruce_goose/docs/current-state.md).
