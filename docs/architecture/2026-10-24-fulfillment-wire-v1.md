# FulfillmentCore JSON event ingress v1

Untrusted JSON is accepted only as a **decoded map** under the exact
`bizkit.fulfillment.event.v1` schema and an independently authenticated host
binding (merchant, request ID and producer authority).

The client body never specifies actor, user or producer. Commerce may request
cancellation. Dispatch may accept/reject, confirm cancellation, report
in-transit/failed, or provide a **reference** to independently verified
delivery evidence. Extra keys, mixed scopes, unknown operations, invalid
references and non-JSON-safe versions are rejected. No dynamic atom creation.

The HTTP decoder must refuse duplicate *raw* JSON object keys before creating
a map. A map cannot prove that the original bytes contained no duplicates.

This is only a syntactic guard. The Dispatch host must verify signed
principal/device grants, committed request ownership, sequence/revision,
evidence custody and atomic append, with outbox/inbox retry reconciliation.
No route, writer, DB migration or courier assignment is created by this PR.
