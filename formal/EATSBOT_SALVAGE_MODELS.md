# Proof-driven gates for Eatsbot salvage: abstract candidate states

Status: **Proposed finite Quint abstraction, no authoritative admission or live-money capability**.
Related [decommission #176](https://github.com/larsbx/biz-kit/issues/176),
[MarketingCore #177](https://github.com/larsbx/biz-kit/pull/177),
[DispatchCore #178](https://github.com/larsbx/biz-kit/pull/178),
[MarketingBridge #179](https://github.com/larsbx/biz-kit/pull/179),
[LastMileBridge #180](https://github.com/larsbx/biz-kit/pull/180).

## Formal questions

- \`quint/eatsbot_marketing_candidate.qnt\`: an attributed conversion must
  follow current consent and *independently verified* delivery proof from
  the same consent epoch; duplicate/restart events cannot create a second
  credit. Regranting after withdrawal does not revive a stale delivery.
- \`quint/eatsbot_delivery_candidate.qnt\`: business completion requires a
  verified pickup and a verified delivery. A late physical delivery after
  cancellation request cannot be erased or silently marked complete. Unknown
  status remains held.
- \`quint/eatsbot_marketing_bug.qnt\` is the deliberately insecure design:
  it credits without consent or delivery proof and must produce an actual
  invariant violation, **not** merely a parser/typecheck error.
- Nonvacuity witnesses require model executions reaching credited, delivered
  and held states, so a model that does nothing cannot pass silently.

## What the checks do *not* prove

These are bounded models of abstract booleans and phases. They do not verify
actual signed \`CoopSubstrate.Protocol.Envelope\` bytes, channel provider
receipts, legal consent, exact marketing Money rounding, Dispatch device proof,
PostgreSQL atomicity, full Elixir implementation refinement, inter-node
coordination, final Hawala payment, production liveness or live compliance.
\`quint verify\` bounded success is **not** a general kernel proof. Lean
inductive safety over the corresponding abstract transition relation and
generated trace replay against the admitted business-event implementation
remain required before enabling real mutation pathways.

## Code-to-model refinement obligations

| Abstract operation | Required actual source-evidence admission |
| --- | --- |
| \`grant\`, \`withdraw\` | SalesCore consent event, currently authorized scoped grant, full history and nonreusable evidence ID |
| \`verifiedDelivery\` | Provider-authenticated actual delivered receipt, canonical bytes and source/audience/campaign/time/tenant binding; no queued-message shortcut |
| \`credit\` | One serialized signed business event, current consent/receipt revision, merchant/campaign uniqueness and deterministic replay |
| \`ready\`, \`pickup\`, \`observedDelivery\` | Dispatch source identity and grants; separately custody-verified physical evidence |
| \`requestCancel\`, \`uncertain\` | FulfillmentCore source-owned cancellation and durable reconciliation/HOLD; a timeout alone is not physical failure |
| \`reconcile\` | Verified authority result, not simply a model state or opaque source ref |
| \`restart\` | Replay from actual signed append history; a volatile wakeup never licenses a second effect |

The current pure PRs are **candidate/preflight** only. They explicitly do not
satisfy the database, signer, privacy, settlement or production gates above.
