# Provider re-attestation of existing held group-buy funding

Date: 2026-10-28. Follow-up to #149, within #143. This admits signed external
observations to the existing seller-home Log/EventStore. It neither establishes
actual custody nor requests, transfers, releases or refunds money.

## Recovery boundary

After #149, rotating/renewing a governance provider authorization invalidates
old campaign pins and funding ancestry for new coverage and stock readiness.
Repinning the current key alone must not relabel historical evidence as current.
The prior implementation intentionally stopped there: a second `hold_confirmed`
would duplicate an already claimed allocation and was refused.

The new provider-proof operation `hold_reconfirmed` describes the SAME held
allocation, under the currently authorized and seller-home-pinned provider key.
The signed payload contains all existing hold fields plus
`prior_funding_evidence_ref`, the exact hash of that position's most recently
admitted funding report. The provider signature binds the prior report, original
buyer/pledge/provider/custody identity, exact currency/amount, renewed hold
horizon, campaign/seller/offer revision and fresh provider event identity/time.
Old operation encodings and signatures are unchanged; older verifiers refuse
the new operation until upgraded.

## Invariants and commit

- Only an existing `:held` position can be reconfirmed. No new position or
  custody allocation is created. The provider, custody reference, buyer,
  pledge, currency and exact monetary amount must match the prior position.
- The signed prior evidence hash must match the position's current funding
  hash. Concurrent or delayed reports cannot branch from an obsolete receipt.
- The observation must be fresh under the current active authority and V2 pin;
  old/forged keys, wrong campaigns and missing grants fail at the append gate.
- Protection cannot be shortened. The new horizon must be within the exact
  integer bound and later than both admission time and campaign deadline.
  An expired held observation can only recover through a fresh provider-signed
  observation with a live horizon. This code does not extend the actual hold.
- Released, refunded and disputed positions cannot be resurrected or unfrozen.
  Expired, unbound pledges cannot be reactivated by a custody report. Refund,
  cancellation and dispute resolution remain separate lawful workflows.
- Existing `(provider_id, event_ref)` nullifiers retain every earlier report.
  Re-attestation uses a new provider event reference and the SAME global
  custody claim. Its ownership cannot change; only authenticated provenance
  is advanced to the current authority event after the reducer accepts.
- The seller countersigns the canonical report using the existing
  `GroupBuyEscrowEvidenceAdmittedV1` event and current expected escrow version.
  Signature verification, prior-evidence validation, evidence update and
  provenance refresh all commit together through the one canonical Log.
- Exact callbacks acknowledge the original commit without advancing head or
  funding twice. A changed receipt under the same event identity conflicts.
  Journal replay/restart reconstruct both evidence and provenance together.

A valid recovery can restore `complete_coverage` and stock readiness if all
other requirements still hold. It leaves contracts, stock quantities,
reservations and original reservation expiry unchanged. An expired stock
reservation remains expired; no fulfillment or settlement authority is gained.

Legacy seller-only V1 funding can gain current ancestry only after the current
independently authorized provider explicitly signs its exact existing allocation
and prior receipt. The historical records are preserved. Governance renewal or
a seller signature alone is insufficient.

## Validation and remaining external work

Regression coverage includes rotated keys, altered money/identity, wrong prior
hash, shortened horizon, expired held evidence, terminal/disputed positions,
legacy migration, cross-campaign reuse, duplicate callback acknowledgement,
concurrent re-attestations, unchanged stock and deterministic restart/replay.
Run `scripts/test-group-buy-authority.sh` for PostgreSQL-backed admission and
ledger checks, and the GroupBuyCore and federation checks.

The provider must independently reconcile real segregated balances and issue
honest observations. Provider qualification, lawful custody/consumer terms,
provider-global allocation uniqueness across installations, provider/network
partitions and loss-of-protection reporting remain external requirements.
Independent inventory, unified cash/barter/group stock admission, verified
delivery, provider-controlled release/refund and durable execution recovery
also remain open in #143. No operational escrow account or money movement is
claimed by this milestone.
