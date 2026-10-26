# Escrow-backed group-buy stock readiness — one seller-home Log

Date: 2026-10-26. Scope: seller-signed **inventory evidence and reserved
quantities** combined with admitted external-provider escrow reports.
Not proof of physical warehouse stock, money in custody, payment settlement,
legal cancellation rights, or permission to dispatch goods.

## Purpose

A binding group-buy round is not sufficient to authorize fulfillment.
Even provider-signed escrow reports alone do not establish the seller has
goods available to deliver. The trusted seller-home must have separately
admitted stock evidence and a current scoped reservation, checked against
the same accepted group terms and funding coverage.

`CoopSubstrate.GroupBuys.Stock` integrates the existing portable
`InventoryCore` under the **one** `CoopSubstrate.Log`. The registered
`GroupBuyStockCommandAdmittedV1` event is private and seller-signed.
There is no separate stock or escrow event store.

## Authority and computation

- The event pins seller, campaign, typed InventoryCore.Wire command and
  stock-source evidence reference. The canonical append gate verifies
  the seller-home's currently authorized signing key and current timestamp.
- The offer's immutable seller/SKU/unit defines the only admissible inventory
  scope. Caller-asserted merchant, item, unit, operation, command revision
  and amount must pass exact `InventoryCore.Wire` validation. Dynamic atoms,
  noninteger quantities, additional/unknown fields and foreign scopes fail.
- Only seller-reported `:receive` and bounded `:reserve` commands are
  currently accepted here. Receive is a seller **attestation**, not
  independent physical-stock verification. Release, commit, adjustment and
  expiry workflows require separately specified lawful authority.
- InventoryCore is projected **once per (chapter, seller, SKU, unit)**, across
  all group campaigns in that business ledger, with optimistic versioning,
  deterministic replay, idempotency and an on-hand-minus-reserved invariant.
  Two fully funded group campaigns cannot reserve the same five units twice.
- The seller-home admits a group reservation only after the binding round
  reached its published minimum, the proposed quantity equals the entire
  current contracted quantity, and **all** member funds are independently
  evidenced by currently held and unexpired external escrow positions.
  Reservation expiry must occur within every protected position's horizon.
  This is an append-time gate, not a read-only shopping-cart preview.
- Each accepted campaign reservation pins the binding terms hash, quantity
  and stock revision. `Stock.readiness/5` recomputes the current
  BindingRound and Escrow coverage from the seller-home Log projection and
  checks that the exact reservation is still active, unexpired and covers
  the entire bound quantity. A later changed commitment, missing funding,
  refunded/disputed or expired position, or stale hold refuses readiness.
- Even a successful readiness projection is explicitly
  `physical_stock: :not_independently_verified`,
  `provider_custody: :requires_fresh_provider_reconciliation`,
  `settlement: :not_authorized`, and
  `fulfillment: :requires_external_delivery_checks`.
  The app never sends payment, releases escrow or dispatches goods.

The single Log's preflight tests the entire typed inventory command against
current group/escrow/stock projections before any append. A rejection
advances neither the ledger head nor any projection. Accepted events replay
identically after restart and retain their original grant/receipt evidence.

## Important gaps

1. **Physical custody and seller evidence:** a seller-signed `:receive`
   report is not an inspection, warehouse-count attestation, possession
   proof or commercial stock guarantee. Production must attest stock
   independently, honor warehouse-specific custody and prevent fabrications.
2. **Ordinary cash and barter checkout:** the shared projection here only
   serializes **group-buy inventory events admitted through this Log**.
   Existing independent CommerceCore cash orders and barter reservations
   are not yet routed through this same stock writer; therefore no general
   prevention of *cash-versus-group* overselling can be claimed.
3. **Escrow reality:** a qualified, legally permitted provider must
   independently validate real held funds and use global allocation IDs
   across every seller installation; merely verified Ed25519 statements
   and local canonical nullifiers are necessary but insufficient.
4. **Atomic fulfillment and money transfer:** no paid/settled/fulfilled
   status is produced here; connect lawful delivery proof, inventory commit,
   provider release/refund, outbox replay and cancellation/refund remedies
   through the same signed commit-before-execute boundary.
5. **Campaign changes:** a reservation binds the entire exact current
   round. New binding members or deeper discount tiers invalidate its
   hash; production requires a separately authorized, versioned expansion
   or closing policy before becoming ready again. Neither old holdings
   nor old escrow statements should be silently re-used.
6. **Operational constraints:** buyer and seller eligibility, taxes,
   fees, shipping, disputed deliveries, inventory shrinkage, cross-node
   partitions and legal enforceability need domain-specific handling.
   Members-only prices, buyer pledges and custody evidence never go to
   public federation traffic.

The remaining production implementation is tracked in
[Issue #143](https://github.com/larsbx/biz-kit/issues/143).
