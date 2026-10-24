# CommerceCore — reusable business rules

First extracted business kernel of the [biz-kit modular platform](../../docs/architecture/2026-10-24-modular-business-platform.md).

`CommerceCore.Pricing.price/3` computes line subtotals and a nonnegative
order total from Money-valued line snapshots and named adjustments. It rejects
empty orders, zero/negative quantities, mismatched currencies, negative inputs,
excessive line discounts, and negative totals. It never silently performs FX,
tax calculation, promotions, payment execution, inventory reservation or
restaurant fulfillment.

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
