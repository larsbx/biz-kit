# FulfillmentCore — commerce/transport handoff

Typed pure request and replay mechanism shared by Eatsbot and Dispatch.
The commerce order is **not** the dispatch trip or driver assignment.

- `FulfillmentCore.new/4` creates an opaque request candidate, with no
  customer address or private recipient details.
- `:commerce` may request cancellation. Only `:dispatch` may accept,
  refuse, confirm cancellation, report movement, failure and delivery proof.
- Duplicate identical events are idempotent. Conflicting IDs and stale
  versions are refused. A cancellation of accepted/in-transit transport
  remains pending until transport confirms it.
- Domain adapters `EatsbotCore.Orders.FulfillmentBridge` and
  `Dispatch.FulfillmentBridge` are **pure**. No web routes, dispatch
  assignments, outbox jobs or order state migrations are added.

Run `mix test --no-start` from `apps/fulfillment_core`. The immutable
request identifiers and proof receipt refs are not evidence that a delivery
actually happened without authenticated transport signer and artifact custody.

## Cancellation races and transport truth

Commerce cancellation is a **request**, not a completed cancellation.
Once transport accepts, its immutable reference cannot be overwritten by a
second acceptance. Late Dispatch rejection can resolve cancellation before
any trip was accepted. If Dispatch reports that transport started while a
cancellation is still pending, the handoff records that fact without
silently cancelling. A verified delivery receipt can then resolve as
`:delivered` even when the customer requested cancellation; financial
refunds and disputes remain commercial-domain decisions, not trip state.
A terminal `:cancelled` cannot later be rewritten as delivered; late
irreconcilable real-world evidence requires a separately admitted
correction/incident workflow.

## Eatsbot coupling safety characterization

`FulfillmentCore.OrderCoupling` is a pure compatibility policy for the legacy
order/delivery relation, independently usable without Eatsbot or Dispatch.
It does not authorize transport or certify the meaning of archival `Stale_*`
states. The host must verify the producer, bind the merchant/request/order,
and atomically admit both candidate projections. `apps/dispatch` remains the
transport writer; the handoff protocol above still owns cancellation recovery.

The 307-record `delivery_coupling.jsonl` is copied unchanged from
[`larsbx/eatsbot@15a201ee1279bffce09ab200609c2490f219af8c`](https://github.com/larsbx/eatsbot/blob/15a201ee1279bffce09ab200609c2490f219af8c/eatsbot/test/fixtures/characterization/delivery_coupling.jsonl),
SHA-256 `8da0ca087ebd04ab1c57a8573336473620898a740ba8a8d6415092f021f81187`.
Tests check every record, with these explicit safety differences:

- Alpha and edge ownership remain unchanged. Valid same-owner mirror values
  remain unchanged. Opposite-owner requests refuse even if the old helper
  returned `:none`; a no-op must not bypass the authority boundary.
- The actual fixture contains 34 `KeyError` observations: 25 delivery-owned
  requests now return `{:error, :delivery_owned}`; nine acceptance requests
  from inconsistent delivery states return `{:error, :inconsistent_coupling}`.
- Projection helpers describe mirrors, not source admission. `step/4` additionally
  requires the source pair to satisfy I8 and the owned edge to exist. Tests
  exhaust every delivery destination from each recorded consistent pair,
  preventing invented edges as well as lost edges.
- Order cancellation can mirror to the legacy aborted state only for a consistent
  pre-dispatch pair. In-transit cancellation remains the existing pending
  handoff protocol; this extraction does not turn a cancellation request into
  transport completion, a refund or financial settlement.

Validation: Elixir 1.19.0 / OTP 27.3.4, strict core compilation, 17 tests, zero
failures. Jason is a test-only decoder, already pinned by the umbrella lock.
The suite rejects deliberate removal of the mirror-owner check or the
source-coupling check. The existing handoff tests continue to cover duplicate
events, replay conflicts, revisions, cancellation races and late observations.

This advances only R1/R2c of [issue #176](https://github.com/larsbx/biz-kit/issues/176).
R0 production inventory, R3 authenticated admission/durable outbox, R4 migration
and rollback, R5 single-writer cutover/reconciliation, and R6 retirement remain
required. No runtime, release dependency, production writer or deployment changes.
