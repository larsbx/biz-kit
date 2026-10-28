# Cross-domain commercial/transport fulfillment contract

Follows biz-kit #83; 2026-10-24. Scope: pure handoff semantics.

Commerce/Eatsbot owns the commercial order and restaurant kitchen state;
Dispatch owns transport acceptance, route/driver assignment, location
observations and transport proof. These are different aggregate roots and
their databases are not one transaction.

This slice implements request/ack/reject/cancel/cancel-confirmed/in-transit/
delivery/failure with actor-class and revision guards, stable idempotency IDs
and pure replay. It has real, minimal bridge modules in both domain apps and
restaurant + nonrestaurant freight fixtures. No endpoint, background retry,
external delivery integration or writer cutover is implemented.

Before production handoff, specify envelope signing, customer-data access
grants, request uniqueness over partner+order, durable outbox/inbox and retry,
failover/reconciliation after crash or timeout, cancellation races, append
watermarks, transport proof custody and project-scoped disclosure. Do not
treat an unverified `:dispatch` atom passed to a pure function as authority.
Keep the existing Eatsbot order/delivery I8 parity tests and d-patch
OpenAPI/device tests; retain its current delivery writer until the
cross-service authority boundary has separate integration acceptance.

## Cancellation/transport race correction

The transport-side append order is the authority on what happened, not a
commerce customer's cancellation intent. The reducer tracks whether a
Dispatch-origin `in_transit` event was accepted separately from the
`:cancel_requested` phase.

- A second different transport acceptance cannot replace an already
  accepted `transport_ref`.
- Cancellation before acceptance can be resolved by a late Dispatch
  rejection, rather than leaving the handoff pending indefinitely.
- A late Dispatch `in_transit` observation cannot by itself cancel the
  trip; it preserves the pending cancellation and records transport start.
- Proof-bearing `delivered` may close a pending cancellation **only after
  independently accepted transport start**. Without that observation,
  an invented proof reference is refused.
- Host-side proof verification, privacy authorization and durable event
  admission are mandatory and are not implemented by the pure reducer.
- Late transport evidence after a fully confirmed cancellation is an
  operational discrepancy requiring a separately governed incident/correction
  process, not silent mutation of a terminal record.
