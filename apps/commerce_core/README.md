# CommerceCore — reusable business rules

First extracted business kernel of the [biz-kit modular platform](../../docs/architecture/2026-10-24-modular-business-platform.md).

`CommerceCore.Pricing.price/3` computes line subtotals and a nonnegative
order total from Money-valued line snapshots and named adjustments. It rejects
empty orders, zero/negative quantities, mismatched currencies, negative inputs,
excessive line discounts, and negative totals. It never silently performs FX,
promotions, payment execution, inventory reservation or restaurant
fulfillment.

`CommerceCore.Tax.flat/4` computes an order's sales tax once, at checkout, from
one combined rate and whether the delivery fee is taxed. It rounds half-up once
per order and spreads the result across lines by largest remainder, so the
line taxes and the fee tax sum exactly to `tax_total` (I₇), and each share is
within one minor unit of its exact tax. Tips are never an input.
`CommerceCore.Tax.reverse/4` gives the tax a refund reverses, in proportion to
the amount refunded; the refunds of a whole order reverse exactly its tax.
Jurisdiction lookup, marketplace remittance and filing stay with the host;
pass the result to `Pricing.price/3` as `tax_total`.

Neither function holds state or performs an effect. A computed reversal is
not a refund: under the [PostgreSQL event log, Redis and TigerBeetle
decision](../../docs/architecture/2026-10-30-postgres-event-log-redis-consolidation.md),
refunds and other financial operations are accepted only by a confirmed
TigerBeetle commit through the Hawala gateway.

This implementation was lifted from `EatsbotCore.Orders.Pricing` preserving
the original algorithm and error terms; the Eatsbot module now delegates back
to this one. Existing orders, checkout locks, order/delivery state machines,
PostgreSQL schemas, IDs and writers are unchanged. Existing Eatsbot pricing
tests remain a consumer conformance check. New independent CommerceCore tests
can run without database setup:

```sh
cd apps/commerce_core && mix test --no-start
```

In tests, the helper starts Localize's currency loader using the bundled
English locale cache owned by Localize itself, without starting Eatsbot's web,
database, or queue services. Production CommerceCore code never calls Eatsbot.

The only declared runtime dependency is `ex_money`. This kernel does not
depend on Eatsbot, Dispatch, SchoolOps, Ash resources, storage, network,
tenant-specific policies or the umbrella runtime. Its source lives inside
the umbrella; publishing a standalone artifact/version requires a separate
packaging/lockfile validation step and must not imply that the current
umbrella-relative build paths work unchanged in an external host.

**Next:** catalog/price API ownership, inventory reservation design, and
cross-domain order/Dispatch fulfillment interfaces must be reviewed separately
before moving persistent Ash resources or writers.

**Modifiers.** A catalog product may carry `modifier_groups`: each group lists
options with non-negative per-currency price deltas and allows between `min`
and `max` choices. `Catalog.quote/6` takes the chosen `{group_id, option_id}`
pairs in any order and prices the unit at the variant's price plus their
deltas; unknown, repeated or out-of-bounds choices are refused. `quote/5` is a
quote with no modifiers. Properties check the sum, order independence, every
bound and merchant scoping.

**Characterization.** `test/eatsbot_characterization_test.exs` checks this core
against the old eatsbot's recorded behaviour, pinned by sha256 to
`larsbx/eatsbot@15a201e` (rebuild slice 1): all 314 recorded baskets price to the same totals or are refused with the same error term.

**Order and checkout safety.** `CommerceCore.OrderLifecycle` adds a pure,
order-scoped candidate reducer and mathematical history replay.
Host-verified operation grants precede all protected state/revision/history
inspection. `CommerceCore.Checkout` produces immutable priced order candidates,
one per cart, with channel-scoped idempotency and a delivery-request marker.
Both require serialized authenticated host admission; neither is a database or
production writer. Checkout creates no tracking secrets or transport record.

Checkout and lifecycle completion do not accept money. Every checkout candidate
is `financial_status: :unconfirmed`, including duplicate requests containing a
claimed settlement. A computed tax reversal is arithmetic only. Financial
acceptance requires a confirmed canonical TigerBeetle operation through the
Hawala gateway, followed by downstream persistence; this core exposes no
financial-acceptance action.

See [the fixture provenance, intentional differences and remaining migration gates](../../docs/architecture/2026-10-31-eatsbot-safety-compatibility.md).
