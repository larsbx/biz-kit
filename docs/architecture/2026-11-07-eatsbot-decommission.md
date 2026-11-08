# Eatsbot decommission checklist

Date: 2026-11-07. Status: **proposed checklist; nothing here is implemented
by this document.** It restates the
[salvage and retirement plan](2026-10-28-eatsbot-salvage-and-retirement-plan.md)
for the path the code has since taken: the rebuilt eatsbot
(`order_core`, `restaurant_core`, `restaurant_host`, the `restaurant`
release) replaces the legacy runtime, instead of the legacy writer being
migrated in place. It gives "Eatsbot is decommissioned" one testable meaning,
in the form of the [SpruceGoose checklist](2026-11-06-sprucegoose-decommission.md).
Owner decisions are recorded in [Decisions](#decisions).
The plan's R0–R6 work packages and refusal cases still apply; §5 maps them.
Sources: the plan, the [source audit](2026-10-28-eatsbot-source-revision-audit.md),
[safety compatibility](2026-10-31-eatsbot-safety-compatibility.md),
[deploy](../deploy.md), `apps/restaurant_host/README.md`,
`apps/restaurant_core/README.md` and [issue #176](https://github.com/larsbx/biz-kit/issues/176),
read at main `89d5e8a2`.

## Definition

Eatsbot is decommissioned when all four hold:

1. **Surfaces.** Every surface production Eatsbot serves is rehosted on a
   ledger-admitted host or dropped by a recorded owner decision (§1).
2. **Authority.** Each fact has one writer at every instant: legacy writes
   are stopped, queues drained and late outcomes reconciled (§2).
3. **Obligations and history.** Every open obligation has a named surviving
   owner, and retained history is inert audit data that grants no authority
   (§3).
4. **Repository.** The standalone deployment is off, `larsbx/eatsbot` is
   archived read-only after retention, and only then are `apps/eatsbot`,
   `apps/eatsbot_core`, `apps/eatsbot_extension_*`, the `eatsbot` release,
   its `runtime.exs` section and its workflows removed from biz-kit.

Production Eatsbot is deployed by Fly from `larsbx/eatsbot` (`dev`), not from
this repository ([deploy](../deploy.md)). The umbrella copy is not in any
biz-kit production release and diverges from the standalone source in places
([source audit](2026-10-28-eatsbot-source-revision-audit.md)). §1 lists the
umbrella copy's surfaces; the R0 inventory must confirm them against the
standalone `dev` head and the live deployment.

## Decisions

Recorded 2026-11-07 by the owner.

| # | Decision | Consequence |
| --- | --- | --- |
| D1 | **Start empty; migrate nothing.** | No legacy row or baseline event enters the Log. Every legacy obligation is finished on legacy before the switch or handed to a named owner (§3). Customers sign up again. |
| D2 | **Drop the Telegram bot now.** | Its webhook, notifier, ordering chains and touchpoint controller are not rehosted. Marketing policy stays in `marketing_core` and consent in `sales_core`, with no channel adapter until a new channel is chosen. |
| D3 | **Drop GraphQL `/gql` now.** | Not rehosted. Consumers found in R0 are told, not repointed. |
| D4 | **Keep customer accounts**, in `biz_kit_identity`. | No Eatsbot account store. Sign-in yields a biz-kit principal; principals are never merged on name or email. |
| D5 | **Keep discounts**, in `commerce_core`. | The storefront prices with `CommerceCore.Pricing` discount rules instead of a zero discount; no restaurant-specific discount code. |
| D6 | **Keep menu editing without a redeploy**, in `commerce_core`. | Catalog changes are signed events admitted by the Log against a governance grant and read back as `CommerceCore.Catalog` versions, not edits to the restaurant file. |

## 1. Surfaces to rehost or drop

| Surface (umbrella copy) | Rebuilt at `89d5e8a2` | Requirement | Gate |
| --- | --- | --- | --- |
| Guest ordering and checkout | Storefront `/`: catalog menu, `Tax`/`Pricing`, cash at pickup, idempotent checkout key | Card payment only through Hawala; checkout stays financially unconfirmed until then | Slice 4 gate test passes against the deployed host; a card payment is settled by Hawala, never by an order step |
| Kitchen order lifecycle | Board `/board`: device-signed `RestaurantOrderStepV1`, pairing by secret | Staff sign-in, device grant revocation, cancellation reasons at the board | Revoked device's next event is refused; each retained step admitted by a signed event, with a refusal test |
| Menu, catalog, modifiers, availability | Menu from the restaurant file, static per boot; `CommerceCore.Catalog` has modifiers and availability | D6: signed catalog events admitted by the Log; restaurant file keeps only the chapter, merchant and devices | A granted catalog edit shows on the storefront without a restart; an ungranted one is refused; an order keeps the price it was placed at |
| Discounts and promotions | `CommerceCore.Discounts` (percent off, unit price, buy x pay y, x for an amount; weekday, local-hour and quantity conditions; best single rule) on catalog products; storefront applies them at the restaurant's timezone; admission refuses a snapshot that does not add up (I₂). Rules come from the restaurant file | D5 done in code; editing rules without a restart waits on D6 | Holds on the deployed host |
| Deliveries: `/deliveries`, `/map`, `DeliveryAuthPlug` bearer keys, public tracking | Not built (slice 5). Kitchen workflow has `dispatched`, delivery-owned | `DispatchCore` policy, `FulfillmentCore` handoff, `apps/dispatch` as the one transport writer | A delivery order reaches `completed` only on Dispatch-owned proof; no bearer key or GPS proximity counts as proof |
| Customer accounts: AshAuthentication `/auth` (password, magic link) | None: guests give a name | D4: sign in through `biz_kit_identity`; guest checkout stays. No legacy account migrates (D1) | A signed-in customer's orders are bound to their principal; principals are never merged on name or email |
| GraphQL `/gql` | None | D3: dropped | Every consumer found in R0 is told; not served by any retained host |
| AshAdmin `/admin` (basic auth, `ADMIN_API_KEY`) | Governance grants via `mix restaurant.grant` | Drop. The implicit admin bypass does not migrate | Not served by any retained host |
| Telegram bot: webhook, notifier, ordering chains, marketing, QR/NFC touchpoints | None | D2: dropped. Policy stays in `marketing_core` / `sales_core`; a future channel needs its own consent-rechecked outbox | Webhook deregistered with Telegram and bot token revoked at the switch |
| Kafka producer | None | Keep only if R0 finds a consumer | Every consumer found in R0 is repointed or told |
| Prometheus metrics | None | Shared infrastructure, when a second consumer needs it | Decided and recorded |

## 2. Authority cutover

| Condition | State at `89d5e8a2` | Gate |
| --- | --- | --- |
| Rebuilt admission | `RestaurantCore.Admission` refines the kitchen reducer; the Log admits orders and steps from granted devices only | Holds on the deployed host |
| Legacy order and checkout semantics | 48 recorded successes kept, 459 unauthorized requests refused, 207 typed refusals (`order_actions`, pinned to `eatsbot@15a201e`) | Holds |
| Legacy state carried over | D1: none | The Log holds no legacy order, delivery, account or consent; the archive (§3) is the only copy |
| Single writer | Legacy is the only production writer | At the switch instant, legacy order writes are refused and the rebuilt host is the one writer; recorded with time and both release versions |
| Drain | Not started | Legacy stops taking new orders first; open orders and deliveries finish on legacy; Kafka and job queues empty; late callbacks reconciled; unknown outcomes held, not guessed |
| Rollback | Not defined | A rollback window with its exit condition; configuration rollback is not a writer fence |

## 3. Obligations and history

None of it converts into ledger authorization.

- **Open obligations at the cutoff:** unfinished orders and deliveries,
  refunds, unredeemed promotions and redemption codes, commissions, gift
  cards, chargebacks and partner commitments. Since nothing migrates (D1),
  each is finished on legacy before the switch, or gets a named owner and a
  resolution route outside the rebuilt host, or is recorded as none found.
- **Marketing consent:** nothing migrates (D1, D2). The archived opt-outs
  and suppressions must be applied if any legacy contact is ever imported.
  Telegram `:subscribed` flags are not consent and never become grants.
- **Legacy database:** dump, record its digest and where the copies are
  kept, under the privacy and retention rules R0 identifies. Customer PII
  is not copied into the ledger.
- **Characterization fixtures** already pinned by SHA-256 in
  `restaurant_core`, `commerce_core`, `fulfillment_core` and `dispatch_core`
  stay as the record of legacy behaviour, defects included.
- **Source:** `larsbx/eatsbot` archived read-only with its history and the
  migration mapping; not deleted, not made more public.

## 4. Not migrated

Retired with the legacy runtime: Ash resources and tables; bearer delivery
keys; GPS proximity as delivery evidence; implicit admin bypass; PubSub
send-before-confirm notifications; the LiveView and GraphQL templates (as
code; their UX may be adapted). Restaurant kitchen stages stay in
`restaurant_core`, not in `order_core`.

## 5. Mapping to R0–R6

| Package | Status at `89d5e8a2` | Remaining |
| --- | --- | --- |
| R0 baseline and freeze | Source audit of 15 modules only | Deployment, database, PII, consumer (GraphQL, Kafka, Telegram, DNS) and open-obligation inventory at the standalone `dev` head; feature freeze |
| R1 characterization | Seven fixture families pinned: orders, checkout, coupling, pricing, delivery | Marketing attribution Money rounding parity, before any marketing channel is added |
| R2 pure cores | `marketing_core`, `dispatch_core`, `order_core`, `restaurant_core`, `CommerceCore` checkout, tax, pricing and discounts | Catalog edit events for D6 |
| R3 host and admission | `restaurant_host` slice 4: signed placement and steps, device grants, `restaurant` release | Every "Not yet" in its README; delivery (slice 5); D4, D6 |
| R4 parallel proof | Not started | Run the rebuilt host on a real merchant beside legacy, with no dual writes; no state migration (D1) |
| R5 switch and drain | Not started | §2 |
| R6 retire | Not started | Definition, point 4 |

## Open

- **Kafka and Prometheus** stay conditional on R0 finding a consumer.
- **Issue #176** tracks R0–R6 against the 10-28 plan; its checkboxes do not
  yet reflect the rebuild.
