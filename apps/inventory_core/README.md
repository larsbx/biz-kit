# InventoryCore — pure stock and reservation rules

Shared, dependency-free inventory aggregate for the biz-kit platform. It
supports exact integer-unit receipts, scoped reservations, partial commits,
releases, transfers, approved adjustments, expiry and deterministic replay.

```elixir
{:ok, stock} = InventoryCore.new("restaurant", "flour", "grams")
{:ok, stock, :accepted} =
  InventoryCore.apply(stock, "restaurant",
    %{id: "receipt-1", expected_version: 0, op: :receive,
      location: "kitchen", quantity: 1000})
```

Host responsibilities: authenticate and authorize, enforce merchant/item
scope, serialize expected-version admission, append accepted signed events,
persist idempotency indefinitely for relevant retries, publish projections,
and schedule expiry with a trusted clock. Caller-supplied `merchant` and
`approved: true` are NOT credentials. This is a pure validation/replay kernel,
**not an independently authoritative inventory service**.

Stock is partitioned by merchant, item and exact unit of measure. The host
must enforce one authoritative writer per aggregate and prevent cross-unit
arithmetic unless an approved, exact conversion contract is added.
Restaurant-ingredient and vehicle-part fixtures demonstrate portability.
Recipes, batch expiry, hazardous stock, serial numbers, picking/packing and
warehouse devices remain domain extensions.

Run `mix test --no-start` in `apps/inventory_core` (no database required).
