# BarterCore — participant-owned barter matching candidates

Pure Elixir kernel for direct barter in biz-kit's independently administered
federated marketplace. This does **not** exchange money, token balances,
Hawala credit, custody or investment value. No platform intermediary takes
title to goods or services.

Each opt-in supplier can advertise a single **provides** and **needs** asset
(code, exact unit, positive integer quantity), origin-bound owner/intent URL,
source revision and expiry. The host—not this pure parser—must verify the
signing actor, consent to publish, current owner permissions and origin policy.
Public statements never prove inventory possession, service capability,
availability, valuation or reliability.

`BarterCore.routes/3` finds at most 100 deterministic, bounded closed exchange
routes with 2–4 distinct owners from at most 16 inspected intents. A supplier
directly gives its asset to the next participant in the cycle, receiving its
requested asset from the preceding participant. Quantities may differ by
asset, and no conversion or claim of fair value is inferred. A candidate is
**not** a negotiated contract, stock hold, payment or fulfillment obligation.
Search is intentionally incomplete under caps, and independently running
peers can disagree on their current discovery snapshots.

`BarterCore.Agreement.pre_delivery_preview/3` requires one supplied evidence
reference for every owner against the identical canonical route digest, and
then emits only `:requires_independent_local_admission` and unadmitted
conditional delivery entries. It **does not verify signatures or evidence**.
An authenticated host must verify explicit individual consent, term digest,
authority, expiry, stock versions, legal conditions and source provenance,
then independently admit local events in its existing signed ledger.
Counterparty acknowledgments and reconciliation are necessary; there is no
cross-node atomic commit. Compensation/dispute paths must cover one-sided
failure, cancellation and partial performance. InventoryCore holds and
FulfillmentCore/Dispatch handoffs occur only after separate authorization.

To test with Elixir 1.19 / OTP 27:

```sh
cd apps/barter_core && mix test
```

See [the federated barter ADR](../../docs/architecture/2026-10-26-direct-barter.md)
and [tracking issue #131](https://github.com/larsbx/biz-kit/issues/131).
