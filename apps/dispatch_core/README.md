# DispatchCore — portable last-mile policy from Eatsbot

This source-attributed first slice salvages Eatsbot's unlocalized delivery
transition graph (13 edges) and makes a stricter, generic candidate last-mile
state/evidence policy.

- \`DispatchCore.LegacyDelivery\` preserves *exact* permitted source edge
  pairs for source characterization and migration/replay comparisons.
- \`DispatchCore.LastMile\` enforces merchant scope and producer classes,
  stable event IDs, optimistic versions, pickup/exception/delivery proof
  references and replay idempotency. Cancellation does **not** erase real
  observed delivery, and uncertainty holds physical status instead of
  automatically inventing failure.

This is a **pure policy**, not a live transport writer, GPS verifier,
authenticated driver grant or payment service. Existing \`apps/dispatch\` owns
all operational transport state. Existing FulfillmentCore owns the
Commerce-to-Dispatch handoff and cancellation/proof transport protocol.
The host must verify signed producer identity and genuine physical evidence
and append its own canonical business events. Proof references alone do not
prove customer receipt, cash movement or final settlement.

No Ash tables, database, Telegram adapter, personal-data fields or legacy
delivery bearer tokens are imported.

Run \`cd apps/dispatch_core && mix test --no-start\`. CI also verifies
standalone compilation/test outside the umbrella. See biz-kit salvage
issue #176 and the R0–R6 decommission plan in PR #175.
