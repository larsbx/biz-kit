# Halaqa–Buzz integration v1

Status: conformance implementation; production effect authority disabled.

## Boundary

Buzz is the signed collaboration interface. It can carry authorship,
membership, rooms, threads, proposals, and typed attestations. It is not an
authorization oracle. `CoopSubstrate.Halaqa.BuzzBridge` admits an effect only
when the current Halaqa context, delegation derivation, evidence threshold,
tool ceiling, purpose, recipient class, and charter epoch all agree.

The first slice is cooperative dispatch assignment. The bridge derives a
canonical resolution and effect hash, emits an admitted or refused card, and
requires a durable pre-effect append before it calls an adapter. Replay uses
the Buzz event ID as the effect identity. The same identity and bytes are a
duplicate; the same identity with different bytes is a conflict.

## Adoption inputs

The candidate HAI package is bound by its source manifest and by these exact
artifacts:

- `priv/halaqa/hai_v1_model.json`
- `priv/halaqa/hai_v1_envelope_defaults.json`
- `priv/halaqa/hai_v1_fixtures.json`

The focused corpus checks pass, and `test/halaqa_buzz_bridge_test.exs` maps
P1–P20 to executable fail-closed checks. Formal `SpecAdopted` execution remains
blocked because no charter-recognized governance signing key is configured for
this repository. An ephemeral key would not establish constitutional
provenance. Until that ceremony occurs, the implementation is conformance-only
and no Buzz input may produce a live effect.

## Twelve-Factor review

Baseline: upstream `twelve-factor/twelve-factor` `main` at
`655b020ac25eac8f912ccc845094ec16cdf6b30b`.

- Codebase: one versioned integration module in `coop_substrate`.
- Dependencies: no new runtime dependency.
- Configuration: policy, charter hash, epoch, and envelope inputs are explicit;
  no credentials are stored in the repository.
- Backing services: Buzz, PostgreSQL, and Valkey remain attached resources;
  PostgreSQL remains durable authority and Valkey remains non-authoritative.
- Build/release/run: this change is code and fixtures only. It does not deploy
  or enable an effect adapter.
- Processes and concurrency: resolution is pure and deterministic. Idempotency
  state must be made durable before production use.
- Disposability: refusal and append failure invoke no adapter.
- Environment parity: focused tests use the repository's normal EventStore
  setup. A live Buzz-to-ledger canary is still required before cutover.
- Logs: admitted and refused cards are attributable outputs, but production
  logging and metrics are not enabled by this slice.
- Administrative processes: the SpecAdopted ceremony and any production
  cutover remain separate human-governed operations.

## Rollback

Rollback is removal of the bridge call site and its conformance artifacts.
Because this slice does not enable a live adapter, rollback changes no external
effect or canonical ledger history. Once effects are enabled, rollback must
preserve committed certificates and receipts; revocation cannot rewrite them.
