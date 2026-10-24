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
