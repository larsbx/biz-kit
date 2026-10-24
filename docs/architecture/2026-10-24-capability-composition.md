# Business capability composition: proposed checkout and fulfillment

Date: 2026-10-24. Scope: *pure cross-domain acceptance contract*.

The existing CommerceCore pricing/catalog, InventoryCore reservation,
and FulfillmentCore handoff rules are composed through a new
`BizKit.Composition.preview/3` function.

Expected properties:
- One merchant ID must match all sources; stock item must equal selected SKU.
- Catalog price and inventory revision are explicit in the returned preview.
- InventoryCore validates the proposed reservation without mutation.
- Proposed fulfillment remains `:requested` until authenticated Dispatch
  acceptance; no implied courier/driver assignment exists.
- A previously previewed inventory command fails with
  `:stale_stock_version` after an intervening stock event.
- No price, inventory or consent grant is created from a product quote.

The result is **not** an order or atomic multi-aggregate command. A production
host still needs: actual principal/grant validation, merchant/stock scoping,
serialized durable event admission, catalog revision verification on
checkout, inventory transaction recovery, payment authority, fulfillment
outbox/inbox idempotency, and replay reconciliation.

No existing Eatsbot, Dispatch, SchoolOps or production database writer is
modified. CI for this slice checks only pure conformance and separately
does not close issues #81–84.
