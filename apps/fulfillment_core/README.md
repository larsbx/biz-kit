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
