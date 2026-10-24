# BizKit Composition — business capability proposal layer

This app demonstrates one concrete orchestration boundary across previously
extracted portable components:

- Catalog supplies merchant-scoped, revisioned product/variant price snapshots.
- InventoryCore validates a **proposed** reservation against stock availability
  with a separate optimistic stock version.
- CommerceCore.Pricing produces a line-subtotal estimate using zero adjustments.
- FulfillmentCore creates an opaque, still-unaccepted transport request.

`BizKit.Composition.preview/3` returns those proposals *without storing them*.
No checkout is performed and it cannot claim a single atomic transaction
across catalog, stock, commercial order, and Dispatch service. The caller
cannot merely append the returned events: the owning services must
authenticate, authorize, serialize, validate revisions and append through
their respective durable authorities.

The restaurant and freight/parts-store tests prove the same contracts can be
used by two unlike products without importing each other's domain semantics.

This is not a production order writer, inventory service, marketing sender,
financial checkout, or route-assignment endpoint. No tenant or merchant
credential is accepted by the preview function; host authorization is essential.

Run `cd apps/biz_kit_composition && mix test --no-start`.
