# ADR: Modular biz-kit business platform

Date: 2026-10-24. Status: **adopted architectural direction; first implementation slice proposed**.

## Decision

Biz-kit owns **reusable technical and business capabilities**. Eatsbot,
d-patch and SchoolOps are independently evolving domain products that consume
those capabilities, possibly inside the umbrella or through a versioned
package or service interface. Keeping those repositories active is compatible
with one authoritative writer per logical fact. Do not freeze a domain simply
because an implementation is also assembled into biz-kit.

A domain prototype can graduate into the shared platform when its invariants
have been generalized, tested against an original consumer, and exercised by
a second nonidentical domain. This is an **extract-and-adapt** direction, not
permission to copy repositories into permanent duplicate live implementations.
The 2026-10-11 signed-ledger one-source-of-truth architecture still governs
admission and replay wherever the same business facts are shared.

## Three layers

| Layer | Owner/examples | Boundary |
| --- | --- | --- |
| **Technical foundation** | `task_core`, `biz_kit_identity`, scoped grants, `coop_substrate` event/record custody, delivery transport, canonical signatures | Domain-neutral. Portable pure rules vs authenticated server services are separate artifacts. |
| **Business capabilities** | Commerce pricing/catalog/orders, inventory, dispatch, party relationships, sales/CRM, marketing; later HR and finance | Each owns a single coherent business aggregate and source-of-truth contract. Expose versioned ports and policies. |
| **Domain products** | Eatsbot restaurant/kitchen; d-patch logistics field workflows; SchoolOps curriculum/assessments | Compose common capabilities; own domain-specific invariants, UX and deployment. |

**Dependency direction:** foundation -> business capabilities -> product adapters.
Foundation must not import products, and reusable business packages must not
depend on `EatsbotCore`, `Dispatch`, or `SchoolOps`. Integration shells may
assemble modules but must not introduce a reverse domain dependency. Domains
may use local pinned libraries or authenticated versioned APIs, depending on
deployment and language. Android consumes contracts rather than Elixir code.

## Extraction inventory: what is actually present

| Candidate | Existing evidence | First boundary / restraint |
| --- | --- | --- |
| Price arithmetic | `apps/eatsbot_core/lib/orders/pricing.ex`: Money, line/total I₂; Eatsbot property tests cover currencies, positivity, discounts | **First slice:** move pure algorithm verbatim into `commerce_core`, delegate legacy public method. Existing Money/error contracts unchanged. |
| Product/variant/price | Eatsbot Ash `Products.Product`, `Variant`, `Price`, `DiscountRule` use `Eatsbot.Repo` and domain-specific policies/notifier | Extract contracts first. Resolve merchant/tenant scope, price publication, visibility, tax context and idempotent upserts before relocating tables. |
| Orders/carts | `EatsbotCore.Carts.Checkout` locks cart before key lookup, snapshots lines and creates delivery in same transaction | Keep Eatsbot state/writer now. Define a merchant-neutral order proposal/commitment and test concurrency/idempotency parity before changing ownership. |
| Restaurant-delivery coupling | `EatsbotCore.Orders.DeliveryCoupling` mirrors kitchen and delivery edges | **Not** a reusable generic dispatch state machine. Use fulfillment request/receipt/event contract and separate ownership: commerce sale vs dispatch transport. |
| Inventory | No general-purpose inventory resources/stock ledger found in the imported Eatsbot model | **Design first**, not a claimed extraction: explicit stock units/locations, reservations, availability, adjustments, audit, expiry semantics as domain extensions. |
| Sales and marketing | Future reusable business modules; not shown by this slice | Party-scoped CRM, contacts, opportunities, consent and campaign attribution require cross-domain tests. |
| HR and financial operations | Future | Add only under explicit employment and accounting models. Signed operational events are not double-entry postings; financial permissions/PII differ from generic grants. |

## Commerce boundary

Commercial orders own price snapshots, currency, customer-facing amounts and
commercial obligations. Dispatch owns transportation assignments, route,
driver declaration, location consent and transport proof. Eatsbot owns menu
choices, recipes, kitchen timing, food-safety preparation, dine-in and local
fulfillment policies. Order-to-dispatch integration uses immutable request IDs,
accepted/rejected acknowledgments and proof references with independent
reconciliation of failure/retry. Do not directly update Dispatch state from
Eatsbot's transactions or assume those databases form one ACID transaction.

Inventory owns stock quantities, reservation tokens, movements and
reconciliation, not order state or recipe selection. Cross-domain consistency
requires explicitly modeled reservation/commit/release with idempotency and
recovery semantics; do not silently decrement quantities at checkout.

## First implemented extraction proposal

- `CommerceCore.Pricing.price/3` carries Eatsbot's existing arithmetic
  and guards **unchanged** into a dependency-light Mix app (`ex_money`).
- `EatsbotCore.Orders.Pricing.price/3` is an API-compatible delegate.
  The incumbent Eatsbot property suite still exercises the behavior through
  the old API. New CommerceCore unit tests exercise the algorithm without a
  database or restaurant fixtures.
- There is **no database/schema/event migration**, no new task or event writer,
  and no claim of a production deployment or broader commercial model.
- The original function expects well-formed maps and Money amounts. Despite
  its historic 'pure and total' description, malformed map shapes may raise;
  input decoding/validation and expanded error algebra are a separate
  backward-compatibility decision.
- `apps/commerce_core` is reusable inside the umbrella. Packaging it as a
  standalone versioned dependency requires tests outside the umbrella's
  relative build/config/lock paths.

## Rollout and independent-domain conformance requirements

1. Keep source API, errors, currency semantics and idempotency stable. Run
   CommerceCore tests, Eatsbot I₂ property tests, umbrella compile and
   formatting; verify exact tested commit. Do not merge on unit-only failure.
2. Catalog extraction: specify merchant ownership, stable product/variant IDs,
   scoped pricing, revisions, discount policy, and persistence owner.
3. Inventory design: model quantities and concurrent holds, finite validity,
   recovery, audit, expiry and negative-availability policy; get two real
   consumers (e.g. restaurant ingredients and workshop parts) before making
   a generic stock writer.
4. Separate commercial and transport fulfillment contracts and exercise
   Eatsbot/d-patch through cross-repo conformance; preserve legacy deliveries
   until replay/reconciliation proves authority.
5. Only then extract CRM/marketing, with explicit opt-in/opt-out and lawful
   audience restrictions. Later HR and accounting require domain-specific
   controls and independent audits.

**Acceptance of first PR does not authorize switching Eatsbot or Dispatch
production writers**, nor does it close the ongoing platform security gates.
