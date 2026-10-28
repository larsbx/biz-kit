# Catalog product and price wire contract (v1)

`CommerceCore.CatalogWire.decode/2` accepts an already parsed JSON object
with a strict `bizkit.catalog.product.v1` shape. It verifies the asserted
merchant against the host's already authenticated merchant scope and rejects
publication unless the host context supplies a verified publication grant.
Caller-supplied names, addresses and actor roles have no business authority.

The first interoperable vocabulary supports `USD`, `EUR` and `CLP` money
values in **positive exact integer minor units** up to the JSON safe-integer
bound. Unknown currency strings are not converted to atoms. Price lists
refuse duplicate currency entries, missing/extra fields, and excessively
large arrays (max 16 currencies, 64 variants). Only known visibility values
are admitted. Tax context is an opaque **nonempty identifier**, not a tax
calculation or legal approval.

The parser returns `%{expected_version: ..., product: ...}` which the
host must apply to the pure `CommerceCore.Catalog.put/4` rules **under an
authenticated serialized version gate**. This code does not create a
Postgres transaction, modify Eatsbot Ash resources, reserve stock, compute
tax, set a customer-facing final checkout price, or grant any authorization.

External JSON parsers must reject duplicate raw object keys before turning
the input into an Elixir map. A map cannot prove its original bytes had
no duplicates. Production APIs additionally require request-size limits,
rate limits, validated commercial product identifiers, signed provenance,
tenant grants and replay/rollback procedures before moving catalog ownership.
