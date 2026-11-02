# Basket-level stock preflight (InventoryCore)

`InventoryCore.Basket.plan/7` checks multi-ingredient and multi-part stock
requirements against a **single caller-supplied snapshot** of individually
versioned stock aggregates, returning one deterministic command per stock
item. Counts and units are exact positive integers; duplicate items,
cross-merchant stock, unit mismatches, missing items and unsafe quantity
products are refused.

This is deliberately an **unsigned reservation proposal**. It mutates no
stock and makes no durable claim. A caller must not take a successful
result to mean its order is accepted or every ingredient is held.

A real host needs an authenticated merchant/recipe binding, a single active
business-authority admission path and an **atomic transaction across every
affected stock aggregate plus the business command and idempotency record**.
Lock aggregates in stable item order, reread current version/grant/expiry,
admit all commands or none, and durably record the accepted basket ID.
Individual per-item application or a best-effort loop is unsafe: the last
hold may fail after earlier holds have committed.

When a request is retried, retrieve the result of the accepted basket from
the authoritative idempotency record. Do not interpret a mixture of already
accepted item holds and pending item holds as a successfully completed basket.
Concurrent orders, process crash/restart, expiry clocks and cross-database
cutovers require backed tests, not solely this pure preflight.

This module is reusable by a restaurant recipe and a workshop parts kit.
It does not add a kitchen concept to InventoryCore, replace Eatsbot checkout,
or create another stock ledger. See issues #82 and #161.

## Historical reservation retries (corrected)

A stock aggregate's `version` increments on an accepted reservation.
Rebuilding the same basket's reservation command at that new revision would
produce a **different** command from `state.seen[basket_id]`, and
`InventoryCore.apply/3` correctly refuses that changed command as an
idempotency conflict. `Basket.plan/7` must therefore examine the
**original admitted command** in `seen` and the corresponding reservation
before constructing a candidate at the current revision.

- Exact matching recorded `id`, `op`, original expected revision,
  location, quantity, reservation ID and expiration, with consistent
  reservation history, yields `{:error, {item, :already_reserved}}`.
- Reusing the ID with changed location/quantity/expiry, another operation,
  or inconsistent reservation history yields
  `{:error, {item, :idempotency_conflict}}`.
- A new basket ID with no recorded command or reservation continues to
  propose at the **current** stock version.
- A hold may have subsequently been committed, released or expired.
  `:already_reserved` is historical duplicate recognition, **not**
  evidence of an active reservation or authorization to ship.

This per-stock check cannot prove the identity of the **entire basket**:
two different recipes/counts could produce identical per-item quantities,
or a retry might omit an already accepted item. The authoritative host
must bind the original canonical basket request and its complete
item/quantity/expiry set to a durable basket ID and reject any changed
request. Only its atomic commit receipt can establish a fully accepted
multi-item reservation.
