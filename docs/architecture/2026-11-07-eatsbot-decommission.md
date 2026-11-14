# Eatsbot decommission checklist

Originally written November 7, 2026. This checklist restates the
[salvage and retirement plan](2026-10-28-eatsbot-salvage-and-retirement-plan.md)
for the path the code has since taken: the rebuilt eatsbot
(`order_core`, `restaurant_core`, `restaurant_host`, the `restaurant`
release) replaces the legacy runtime, instead of the legacy writer being
migrated in place. It gives "Eatsbot is decommissioned" one testable meaning,
in the form of the [SpruceGoose checklist](2026-11-06-sprucegoose-decommission.md).
The plan's R0–R6 work packages and refusal cases still apply; §5 maps them.
Sources: the plan, the [source audit](2026-10-28-eatsbot-source-revision-audit.md),
[safety compatibility](2026-10-31-eatsbot-safety-compatibility.md),
[deploy](../deploy.md), `apps/restaurant_host/README.md`,
`apps/restaurant_core/README.md` and [issue #176](https://github.com/larsbx/biz-kit/issues/176),
read at main `89d5e8a2`.

## Migration status as of November 14, 2026

**The replacement source is on Biz-kit `main`. Production cutover is still open.**
The production source documented for Fly remains `larsbx/eatsbot` on `dev`.
Continue to treat it as the sole production order writer until the switch is
verified. The owner chose to start the replacement with an empty restaurant ledger.
Finish outstanding legacy obligations on the legacy system or give each a named
owner and resolution path. Retain legacy history as restricted audit material.

| Area | Current status |
| --- | --- |
| Cash pickup | [#348](https://github.com/larsbx/biz-kit/pull/348) merged accounts and scoped order history using prebound Biz-kit identities, signed menu publishing, merchant-funded fixed discounts, staff sign-in for paired boards, and ledger-backed device revocation. |
| Fixed-route delivery | [#349](https://github.com/larsbx/biz-kit/pull/349) merged through the pickup branch and [#378](https://github.com/larsbx/biz-kit/pull/378) integrated the stack on `main`. The pilot uses one configured route and an authorized courier. Dispatch owns transport and uses distinct pickup and drop-off codes tied to the order and assignment. Delivery evidence carries no payment or settlement authority. |
| Source-level evidence | The landed integration SHA `b3ddad4422f6d9d5456fb261fa3ebfd464d427c7` passed all four [restaurant jobs](https://github.com/larsbx/biz-kit/actions/runs/43249065306) and [Dispatch partner acceptance](https://github.com/larsbx/biz-kit/actions/runs/43249064861). Restaurant tests use a signed test client, and Dispatch tests cover assignment preparation separately. The passing [real-worker procurement run](https://github.com/larsbx/biz-kit/actions/runs/43247527978) used procurement orders. |
| Restaurant end-to-end | Draft [#402](https://github.com/larsbx/biz-kit/pull/402) adds the real worker and authenticated courier route to a RestaurantHost checkout fixture, including worker restart and receipt replay. Its [hosted run](https://github.com/larsbx/biz-kit/actions/runs/43578830161) was queued when checked. Packaged staging, outage behavior, and delayed pickup after cancellation still need evidence. |
| Build and compatibility | The LiveView cancel form now uses `order_id`. The standalone Localize boot fallback is on `main` via [#357](https://github.com/larsbx/biz-kit/pull/357). [#395](https://github.com/larsbx/biz-kit/pull/395) restored the truncated substrate modules and fixed the legacy runtime-config fixture. At `0f2745b5727ed34f9c1f657b05322a431be2efb0`, [Restaurant](https://github.com/larsbx/biz-kit/actions/runs/43580446923), [Dispatch](https://github.com/larsbx/biz-kit/actions/runs/43580446794), and [Consolidation](https://github.com/larsbx/biz-kit/actions/runs/43580446893) had no result yet. Draft [#401](https://github.com/larsbx/biz-kit/pull/401) passed the [OTP 26 CommerceCore job](https://github.com/larsbx/biz-kit/actions/runs/43578380785/job/132397600826) at synthetic merge `fc9be6a246afaf124a4644efba9ba32d96d4f7ef` with 24 skips for the OTP 27-only Merchant Pilot suite. Its [OTP 27 standalone checks](https://github.com/larsbx/biz-kit/actions/runs/43578380964) were queued. |
| Separate delivery proposal | [#365](https://github.com/larsbx/biz-kit/pull/365) remains open and unmerged. [#376](https://github.com/larsbx/biz-kit/pull/376) merged its verification runner and launch probes. The runner defaults to the #365 revision. Its address, cancellation, evidence, and activation questions concern that proposal and need separate evaluation against the merged pilot path. |

**Next reproducible gate.** Run the #402 acceptance on its exact source
revision. Then stage both packaged services against disposable databases using
the [fixed-route runbook](../deploy.md#automated-restaurant-delivery-with-dispatch).
Capture one checkout, load and assignment, signed acceptance, pickup and drop-off,
the storefront showing **Delivered**, and the Dispatch assignment reaching
**COMPLETED**. Verify receipt replay, worker outage and recovery, and a pickup
report arriving after cancellation. Record the disposition of each exception.

Keep [issue #176](https://github.com/larsbx/biz-kit/issues/176) open through R0 inventory, R4 parallel proof
without overlapping writer authority, R5 writer fence and reconciled drain
with rollback, and R6 retention and retirement. Confirm GraphQL, Kafka,
Telegram and other consumers in R0. The owner's decision drops GraphQL and
Telegram from the replacement, with consumer notification and queue disposition
still part of cutover.

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

## 1. Surfaces to rehost or drop

The table records the original slice-4 baseline. Use the dated migration
status above for subsequent implementation and decisions.

| Surface (umbrella copy) | Rebuilt at `89d5e8a2` | Requirement | Gate |
| --- | --- | --- | --- |
| Guest ordering and checkout | Storefront `/`: catalog menu, `Tax`/`Pricing`, cash at pickup, idempotent checkout key | Card payment only through Hawala; checkout stays financially unconfirmed until then | Slice 4 gate test passes against the deployed host; a card payment is settled by Hawala, never by an order step |
| Kitchen order lifecycle | Board `/board`: device-signed `RestaurantOrderStepV1`, pairing by secret | Staff sign-in, device grant revocation, cancellation reasons at the board | Revoked device's next event is refused; each retained step admitted by a signed event, with a refusal test |
| Menu, catalog, modifiers, availability | Menu from the restaurant file, static per boot; `CommerceCore.Catalog` has modifiers and availability | Edit the menu without a redeploy, or accept redeploy (**owner decision**) | Decided and recorded |
| Discounts and promotions | None: the storefront prices every line with a zero discount | Rebuild on `CommerceCore` discount rules, or drop (**owner decision**) | Decided; if rebuilt, discount fixtures replay through the storefront's pricing |
| Deliveries: `/deliveries`, `/map`, `DeliveryAuthPlug` bearer keys, public tracking | Not built (slice 5). Kitchen workflow has `dispatched`, delivery-owned | `DispatchCore` policy, `FulfillmentCore` handoff, `apps/dispatch` as the one transport writer | A delivery order reaches `completed` only on Dispatch-owned proof; no bearer key or GPS proximity counts as proof |
| Customer accounts: AshAuthentication `/auth` (password, magic link) | None: guests give a name | Drop accounts, or sign in through `biz_kit_identity` (**owner decision**). Never merge principals on name or email | Decided and recorded |
| GraphQL `/gql` | None | Inventory its consumers in R0; rebuild on signed commands or drop (**owner decision**) | Every consumer found in R0 is repointed or told |
| AshAdmin `/admin` (basic auth, `ADMIN_API_KEY`) | Governance grants via `mix restaurant.grant` | Drop. The implicit admin bypass does not migrate | Not served by any retained host |
| Telegram bot: webhook, notifier, ordering chains, marketing, QR/NFC touchpoints | None | Rebuild as a channel adapter on `MarketingCore` and `SalesCore` with a consent-rechecked outbox, or drop (**owner decision**) | Opt-outs carried forward (§3); attribution only from evidenced delivery |
| Kafka producer | None | Keep only if R0 finds a consumer | Every consumer found in R0 is repointed or told |
| Prometheus metrics | None | Shared infrastructure, when a second consumer needs it | Decided and recorded |

## 2. Authority cutover

| Condition | State at `89d5e8a2` | Gate |
| --- | --- | --- |
| Rebuilt admission | `RestaurantCore.Admission` refines the kitchen reducer; the Log admits orders and steps from granted devices only | Holds on the deployed host |
| Legacy order and checkout semantics | 48 recorded successes kept, 459 unauthorized requests refused, 207 typed refusals (`order_actions`, pinned to `eatsbot@15a201e`) | Holds |
| Legacy state carried over | Pending at this historical baseline. Owner later chose to start empty. | Retain the legacy audit archive (§3) and finish or assign every outstanding obligation. No legacy row grants ledger authority. |
| Single writer | Legacy is the only production writer | At the switch instant, legacy order writes are refused and the rebuilt host is the one writer; recorded with time and both release versions |
| Drain | Not started | Telegram webhook, Kafka and job queues empty; late callbacks reconciled; unknown outcomes held, not guessed |
| Rollback | Not defined | A rollback window with its exit condition; configuration rollback is not a writer fence |

## 3. Obligations and history

None of it converts into ledger authorization.

- **Open obligations at the cutoff:** unfinished orders and deliveries,
  refunds, unredeemed promotions and redemption codes, commissions, gift
  cards, chargebacks and partner commitments. Each gets a named owner and a
  resolution route, or is recorded as none found.
- **Marketing consent:** opt-outs and suppressions carry forward to
  `SalesCore`. Telegram `:subscribed` flags are not consent and do not
  become grants.
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
| R1 characterization | Seven fixture families pinned: orders, checkout, coupling, pricing, delivery | Marketing attribution Money rounding parity |
| R2 pure cores | `marketing_core`, `dispatch_core`, `order_core`, `restaurant_core`, `CommerceCore` checkout and tax | Discounts, if kept (§1) |
| R3 host and admission | `restaurant_host` slice 4: signed placement and steps, device grants, `restaurant` release | Every "Not yet" in its README; delivery (slice 5); the owner decisions of §1 |
| R4 parallel proof | Not started | Run the rebuilt host on a real merchant beside legacy, with no dual writes; the state decision of §2 |
| R5 switch and drain | Not started | §2 |
| R6 retire | Not started | Definition, point 4 |

## Open

Use the dated status above for the current gates. Map the R0 inventory, R4
parallel proof, R5 authority switch and R6 retirement evidence back to
[issue #176](https://github.com/larsbx/biz-kit/issues/176).
