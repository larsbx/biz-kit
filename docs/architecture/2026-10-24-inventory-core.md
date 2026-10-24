# Inventory first-stage acceptance and authority boundary

Linked to biz-kit #82; 2026-10-24.

Delivered in this slice: deterministic pure rules for receive/reserve/
commit/release/transfer/approved adjust/expire, optimistic concurrency,
idempotency and invariant reconstruction, with restaurant and workshop
conformance fixtures. No generic inventory existed to import from Eatsbot.

Still required before calling the business inventory module a production
service: signed ledger event type registration and permission grants;
merchant+item+unit aggregate serialization in a real append gate;
trusted clock and durable scheduled expirations; cross-item and cross-owner
transfer saga design; expiry/use-by/batch serial tracking where needed;
replay after crash, checkpoint verification and integration tests with
PostgreSQL/eventstore. Inventory snapshots or an unsigned client command
must never create business state without authorized admission.

No changes to the current Eatsbot stock representation, order checkout,
Dispatch transportation, financial accounting, or existing database schema
are implied. Client-supplied `approved` is only a pure precondition; a
server-side grant and supporting evidence must authorize adjustment.
