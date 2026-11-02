# Eatsbot home/merchant boundary and persistence admission

Date: 2026-11-01. Tracks #233 and the Eatsbot salvage/retirement plan (#176).
Status: focused candidate guards and regression tests; **shared database admission
remains closed**. No production configuration, schema, writer, WorkOS or NetBird
cutover. Legacy runtime/database isolation remains required.

## Source and evidence boundary

Inspected Biz-kit main `a598cece118f6ab40a572b15a2c56ea5ce5857b6`.
The preceding T0 audit and Dispatch changes are on PR #234 at
`cdb47869082006df2c575fcd02b661b51a967484`; that PR is still separate.
Its two-connection revocation/suspension tests already exist and are not recreated
here. Their hosted acceptance and integration into main remain independent.

The observations below establish missing ownership controls in source, not an
observed exploit, production data leak or a complete deployed-schema inventory.
`test/eatsbot/tenant_dependency_test.exs` exercises an artificial tenant resource;
it does not certify the actual catalog/cart/order resources.

All legacy paths below are under `apps/eatsbot_core/lib/` unless qualified.

| Surface | Observed ownership, authorization and access | Consequence / pending control |
| --- | --- | --- |
| `brands/brand.ex`, `brands/branch.ex` | Branch belongs to brand; brand has one branch in the resource declaration. Public reads; admin bypass. No link from these to products, carts or orders. `hq_url` is metadata, not authority. | A brand/branch is not proof of a Biz-kit merchant or home. Franchise, branch sharing and catalog-owner mapping require explicit classification. |
| `products/product.ex`, `products/variant.ex` | Product has type, options, variants, prices and collection joins; variant belongs to product (nullable). Neither declares home/merchant tenancy. Reads broadly allow; admin actor attribute bypass is unscoped. Enabled listing filters state; `search_enabled` only filters name. | No merchant-safe root predicate to propagate through relationships. Search, pagination, counts, admin and field policies require the same owner boundary; publication is a separate rule. |
| `products/option.ex`, `option_value.ex`, `product_option.ex`, `variant_option.ex`, `collection_product.ex` | Option belongs to product; value can reference option/variant. Association resources join bare IDs. Option identity `(name, product_id)`; variant identity `(option_value_ids, product_id)`. | Foreign-ID joins and nullable parents cannot establish ownership. Decide whether types/collections/options are home-owned or explicitly global reference data. No implicit global directory exception. |
| `products/price.ex` | Price may reference product and/or variant; SQL currency extraction `(money).currency_code`; unique indexes `(currency, product_id)` and `(currency, variant_id)`. Public reads/admin bypass; relationship writes use upserts. | Decide exactly-one-parent or explicit consistent dual-parent semantics. Enforce same-owner parent and conflicts; currency alone does not scope a price. Quarantine orphan/conflicting rows. |
| `carts/cart.ex`, `carts/cart_line.ex` | Cart has status/currency but no customer principal, merchant, branch or home. Both have unconditional policy bypass. GraphQL gets carts by ID, creates carts and mutates/checkout by IDs. `add_variant` globally fetches variant and prices, then creates relationship lines; identity `(variant_id, cart_id)`. | A cart UUID is not a verified owner or capability. Anonymous/session/POS ownership and transfer must be decided. Cannot safely bolt on customer ownership from a nonexistent field. |
| `carts/discounts_calculation.ex`, `total_calculation.ex`, `cart_line.ex` | Cart loads line→variant→prices and rules; SQL subtotal uses variant/prices/cart-line/cart relationships and cart currency. No tenant predicate on these paths. | Tenant filters must cover nested calculations, aggregates and SQL joins as well as root reads. Same-currency foreign prices are still foreign. |
| `carts/checkout.ex` | Transaction locks cart `FOR UPDATE` by bare ID, loads lines/variant/prices. Looks up existing order globally by `(channel, idempotency_key)` as `ActorIn.system()`. Same cart returns keys; another cart reports collision. Places order, completes cart and optionally creates delivery. | Existing idempotency and locks serialize operations; they do not authorize cart ownership. Bind owner/principal before lock, reads or retry results. A lock on one cart does not serialize two different carts using the same key. |
| `orders/order.ex`, `actor_in.ex` | Internal read/board use role labels; admin bypass and system actor have no home. Public track uses bearer tracking UUID. Placement snapshots amounts/lines. Unique cart, `(channel, key)`, `(channel, external_ref)` and tracking indexes are not merchant-scoped. | Staff/system/admin roles must carry current exact home authority. Define scoped public tracking separately; do not silently promote bearer keys into a host grant. Preserve immutable financial snapshots. |
| `orders/order_line.ex`, `order_state_change.ex` | Bare order/variant IDs; line variant nullable for marketplace imports. System creates lines/history; internal roles read. History identity `(order_id, sequence)`. | Child records inherit the order owner permanently, even if a catalog variant is deleted. Import source bindings and composite FKs must prevent foreign parents. |
| `orders/transition.ex`, `sync_from_delivery.ex` | Count/create history, load delivery, fetch/update order as system; same-database bidirectional order/delivery transitions. | Every internal read/write needs exact home context and an owner-validated edge. Retain existing authority until Fulfillment/Dispatch cutover; no additional authoritative writer. |
| `products/catalog_bridge.ex` before this change | `preview(merchant, loaded_product)` attached an arbitrary merchant label to already-loaded, unowned data. | That signature cannot prove ownership. It now uniformly refuses; the guarded isolated-source path is described below. |

### SQL and non-Ash paths

Persistent business resources use `AshPostgres.DataLayer` with `Eatsbot.Repo` and
`public` tables. This inspection found SQL-sensitive paths through generated Ash
queries, calculations, relationship upserts and `Query.lock`, rather than a
separate handwritten catalog SQL service. That is not an assertion that all raw
SQL in the estate was audited.

`products/variant_generator.ex` obtains the repository dynamically, starts a
transaction, creates variants/relationships with `authorize?: false`, and rolls
back on failure. `products/product.ex` option creation and
`products/add_value_to_product.ex` contain explicit authorization bypasses.
`apps/eatsbot/priv/repo/example_seeds.exs` directly calls `Repo.delete!` and uses
multiple `authorize?: false` seed writes. Keep seeds/migrations privileged and
outside tenant-facing paths; a resource policy alone cannot protect them.

Actual DDL evidence is in
`apps/eatsbot/priv/repo/migrations/20250228122847_products.exs`,
`20250304135428_price_identities.exs`, `20250304164127_carts.exs`,
`20250307145708_reference_delete.exs` and `20261023014323_add_orders.exs`.
They create ordinary parent-ID FKs and the identities above; they do not introduce
a home/merchant discriminator or RLS. Resource snapshots are historical evidence,
not the deployed database. Audit actual constraints/data before any migration.

Order PubSub publishes `orders:created` and per-ID updates without a home prefix;
Kafka delivery notifications carry resources on `eatsbot-deliveries`.
Host subscriptions, outbox payloads, jobs, logs, exports, caches and search keys
must be owner-bound too; query guards cannot certify these channels.

## Ownership contract for the next host boundary

1. Every business aggregate has immutable **`{home_id, merchant}`** ownership.
   `merchant` is the platform organization/seller identity; home is the authority
   and storage boundary. The pair is explicit even when a deployment currently
   uses one home per merchant. Brand, branch, hostname, actor role and UUID do not
   substitute for either value. Multi-organization principals select one current
   assignment; their memberships are not unioned.
2. The server resolves current principal, acting organization, home and exact
   operation/resource grant. Owner values come from persisted source bindings,
   never client-supplied booleans or identifier labels. Cross-home refusal happens
   before protected lookup, price calculation or duplicate/error disclosure.
3. Variants/prices/options and association rows inherit validated catalog ownership;
   cart lines share their cart's owner and reference only that owner's catalog.
   Orders/lines/history keep their owner and price snapshot after catalog removal.
   A customer principal is an additional cart access condition, not the merchant.
   Anonymous cart identity/claiming requires a separate reviewed contract.
4. Idempotency belongs to `(home_id, merchant, channel, idempotency_key)`;
   external imports similarly scope `(home_id, merchant, channel, external_ref)`.
   One order per owner/cart. Identical retries require current authorization and
   the original principal/cart; foreign ownership never returns a prior order.
5. There is exactly one authoritative business writer per home. Pure CommerceCore
   values and the read-only bridge are candidates, not receipts. At host admission,
   revalidate grants and writer epoch/fence, commit the canonical durable event
   before effects, and derive SQL projections/outbox atomically or through the
   existing reviewed replay contract. Do not introduce a competing order ledger
   or turn an unconfirmed checkout into financial acceptance.

## Implemented guard scope

`CommerceCore.Ownership` centralizes the explicit owner check. `Catalog.new/1`,
`Checkout.new/2` and `OrderLifecycle.new/3` now accept an owner map containing both
home and merchant. Scoped catalog reads/quotes/writes, cart reads, checkout and
order commands require matching owner context; quote/order results retain home.
Checkout validates imported cart owners, checks cart principal and prior-order
ownership before returning retries, and rechecks authorization for duplicates.
Order commands check home before state/version/duplicate-command processing.

Merchant-string constructors remain for existing portable characterization
fixtures. They are **not** shared-tenant APIs: a home grant cannot silently use
merchant-only checkout/order state, and a merchant string cannot access a
home-bound catalog. No new network endpoint exposes these pure reducers. Host
inputs remain trusted; a caller able to replace the projection or grant map is
outside their security boundary.

`EatsbotCore.Products.CatalogBridge.preview/3` accepts a server-owned isolated
source binding, current host context and a lazy host-owned loader. Required source:
`%{mode: :isolated_runtime, source_id: ..., home_id: ..., merchant: ...}`.
Required context also binds source ID, principal, `granted: true` and
`operation: :catalog_read`. Missing/foreign/revoked/shared bindings refuse before
the loader runs. The source must already be reviewed as one isolated merchant
store; marking a mixed database `:isolated_runtime` is not a review or proof.
The loader must use that exact source and cannot be supplied by a remote caller.
`preview/2` now refuses; repository search found only its characterization test
caller. Inventory external consumers before adopting this adapter API change.

These changes do **not** retrofit the legacy GraphQL/Ash/cart/system policies or
create per-row ownership. Direct legacy access still requires isolated runtime,
database/credentials, subscriptions and routing. No production configuration is
changed. Legacy persistent cart authorization is deferred because its owner and
customer/session relationship are absent, rather than inventing a mapping.

## Migration decisions and PostgreSQL enforcement gates

| Gate | Required decision/evidence before implementation or admission |
| --- | --- |
| Source classification | Inventory deployed stores/writers and actual brands/branches/catalogs, including any mixed stores. Approve a retained mapping `source + legacy table + ID → home + merchant`; never assign every orphan to a default merchant. Decide shared global types and explicit publication/partner grants. |
| Customer/cart ownership | Choose authenticated principal, anonymous session capability, kiosk/POS delegation and claiming/transfer rules. Preserve active carts and orders; backfill with evidence or quarantine. Decide whether carts span merchants (this slice refuses that assumption). |
| Parent and historic ownership | Resolve nullable variants/prices, dual price parents, collection/option sharing, deleted parents, imported lines and cross-owner deliveries. Snapshot owner before nullable FK deletion so history cannot lose it. |
| Migration and writer fence | Reconcile actual source rows, IDs, totals, idempotency/external keys and active obligations. Add nullable owner fields only as a staged migration; validated backfill, collision report, owner immutability and NOT NULL follow review. Keep one writer; read-only shadow comparisons, checkpoint, drain/fence and authorized cutover/rollback. No dual writes. |
| FK and uniqueness controls | Owner-bearing parents need unique `(home_id, merchant, id)` keys and children composite same-owner FKs. Replace unscoped idempotency/external/cart identities with reviewed owner-scoped indexes and matching Ash identities/upsert conflict targets. Audit null semantics and price exactly-one-parent rules. DB race on a scoped key must resolve to the authorized original or a uniform refusal. |
| Resource and internal controls | Use Ash attribute tenancy/owner predicates consistently on root and nested reads, counts, joins, bulk actions, calculations, locks and upserts. Replace global admin/system bypasses with exact internal authority. Ban tenant-changing updates. Audit raw Repo, seeds, jobs, import/export and read models. Never use request merchant as a persistence filter without resolving current authority. |
| RLS/pooling | Review an application role without owner/superuser/BYPASSRLS privileges, FORCE ROW LEVEL SECURITY where appropriate, fail-closed USING and WITH CHECK for both owner dimensions, and transaction-local verified context. Test missing/invalid context, pool reuse/reset, rollback, prepared queries, background work and privileged maintenance separately. `SET LOCAL` is not authority if arbitrary callers can set it. Owner roles and maintenance credentials must not service requests. **No RLS is added here.** |
| Exact-revision PostgreSQL acceptance | Two-home/two-merchant same-name roles, foreign PK/upsert/join, price/variant/association, cart read/mutate/checkout, order board/tracking/history, duplicate/external-key races across different carts, revocation while blocked, positive same-home operations and rollback. Use real independent DB sessions for concurrency, not one sandbox connection. Existing Dispatch races stay in PR #234. |
| Admission | Record actual hosted results at the release SHA, reviewed migrations/constraints/policies, current deployment config, subscriptions/cache/jobs and writer fencing. Until all required gates pass, shared-tenancy acceptance remains unestablished. |

## Reproduction and acceptance record

The focused candidate regressions are
`apps/commerce_core/test/home_isolation_test.exs` and the isolated-loader tests in
`apps/eatsbot/test/eatsbot/products/catalog_bridge_test.exs`.
They cover foreign homes and merchants (including reused merchant/primary IDs),
price/variant lookup, cart principal/identifier access, cross-owner contaminated
snapshots, independent idempotency keys, duplicate reauthorization and same-home
success. They run without starting the legacy runtime or a database.

```sh
cd apps/commerce_core
MIX_ENV=test mix compile --warnings-as-errors
mix test --no-start --seed 0
MIX_ENV=test mix run --no-start --no-compile \
  -r test/test_helper.exs \
  -r ../eatsbot_core/lib/products/catalog_bridge.ex \
  -e 'Code.require_file("../eatsbot/test/eatsbot/products/catalog_bridge_test.exs")'
```

The `CommerceCore extraction` workflow format-checks changed modules and runs both
suites; portable compatibility additionally tests the core on OTP 26/Elixir 1.18.
Local validation passed with Elixir 1.19.0 / OTP 27.3.4 in a standalone copy,
using the seven nonoptional packages at the repository's pinned lock versions:

- Compile with `--warnings-as-errors`: passed.
- Complete CommerceCore suite, seed 0: **7 properties, 51 tests, 0 failures**.
- Guarded isolated-source bridge: **3 tests, 0 failures**.
- Formatting of changed Elixir files and `git diff --check`: passed.

No dependency manifest/lock change. Hosted exact-head CI has not yet been
observed; PostgreSQL acceptance was not run. Pure regression success is not
PostgreSQL, HTTP/GraphQL, RLS, live authority or production-isolation evidence.
