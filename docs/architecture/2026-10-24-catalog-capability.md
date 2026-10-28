# Catalog capability boundary (PR for #81)

Date: 2026-10-24. First stage: **portable candidate catalog rules only**.

- `CommerceCore.Catalog` owns the pure catalog validation, merchant scope,
  optimistic revision, SKU uniqueness, visibility and per-currency price lookup.
- The optional `EatsbotCore.Products.CatalogBridge` projects already loaded
  Ash product/variant/price fields into that contract without mutating data.
- Current Eatsbot Ash `Product`, `Variant`, `Price` and discounts still
  own their existing database tables, current write operations and GraphQL
  transport. They are not replaced or migrated by this PR.
- `quote/5` returns a priced **candidate**, not a committed order, inventory
  hold, tax calculation, or authoritative proof that price is still current.
  Hosts must verify catalog revision and tenant grants at serialized command
  admission; a provided merchant ID is a routing claim, not authentication.
- Product `visibility` and discounts remain domain-specific policies.
  Generic price selection requires an explicit ISO currency key matching the
  Money value and a positive amount. Tax context is retained, not computed.
- Uniqueness of variants and SKUs in the pure projection does not modify
  PostgreSQL identities; safe writer cutover needs a baseline, client and
  event/schema mapping, replay and concurrent update tests.
- School-supplies fixtures exercise a distinct non-restaurant merchant,
  without enrolling students or using learner records.

The follow-on work is to specify versioned catalog read/write APIs, migration
ownership and inventory boundaries before changing production storage.
