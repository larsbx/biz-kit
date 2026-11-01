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
