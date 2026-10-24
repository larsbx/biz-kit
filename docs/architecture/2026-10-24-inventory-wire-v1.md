# InventoryCore untrusted wire boundary, version 1

`InventoryCore.Wire.decode/2` accepts **decoded JSON objects** with only
string keys, exact version `bizkit.inventory.command.v1`, and an explicit
scope comparison against an already authenticated host binding:
`merchant`, `item`, and `unit`.

Version 1 supports `receive`, `reserve`, `commit`, `release`, and
`transfer`. Only known operation/field names map to compile-time Elixir
atoms. Unknown or duplicate-decoded fields, extra keys, foreign merchant
scope, negative, fractional or >2^53-1 quantities, stale schema versions and any
attempt to assert `approved` are refused.

**Not on the external wire:** `adjust` (needs audited privileged approval)
and `expire` (needs a host-controlled trusted clock), even though the pure
InventoryCore rules implement those commands for separately governed hosts.

`decode/2` is **not** permission to append. A host must still verify current
principal/grant, resource ownership, signed request authentication,
idempotency identity, expected stock version, durable atomic append and
event replay. This is a safe deserialization boundary for future APIs and
client SDKs, not an additional writer or an API endpoint.

The versioned command shape is intentionally narrow and is tested without
Postgres, Ash or the web app. It remains compatible with `InventoryCore` as a
standalone Elixir package.
