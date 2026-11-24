# Eatsbot decommission checklist

Originally written November 7, 2026; reconciled November 23, 2026.
This checklist restates the
[salvage and retirement plan](2026-10-28-eatsbot-salvage-and-retirement-plan.md)
for the path the code has since taken: the rebuilt eatsbot
(`order_core`, `restaurant_core`, `restaurant_host`, the `restaurant`
release) replaces the legacy runtime, instead of the legacy writer being
migrated in place. It gives "Eatsbot is decommissioned" one testable meaning,
in the form of the [SpruceGoose checklist](2026-11-06-sprucegoose-decommission.md).
The plan's R0–R6 work packages are mapped in §5 with the later owner decisions
and deployment-specific exceptions. Do not apply the old Fly/production
assumptions to the owner-confirmed disposable test stack.
Sources: the plan, the [source audit](2026-10-28-eatsbot-source-revision-audit.md),
[safety compatibility](2026-10-31-eatsbot-safety-compatibility.md),
[deploy](../deploy.md), `apps/restaurant_host/README.md`,
`apps/restaurant_core/README.md` and [issue #176](https://github.com/larsbx/biz-kit/issues/176),
originally read at main `89d5e8a2`; reconciled against main `40d49e85`, the
[November 16 R0 inventory](2026-11-16-eatsbot-r0-inventory.md), merged #426/#402,
and the standalone retirement work.

## Retirement status as of November 23, 2026

**Legacy source retirement is complete in Biz-kit; host and standalone
infrastructure retirement need their own evidence.** The owner confirmed on
November 16 that Eatsbot runs through Biz-kit and `adder-ws` is a disposable
test stack with no customer data. The approved switch starts the rebuilt
restaurant host and removes the legacy apps. No archive or drain is needed
for that stack. For any other legacy copy, inventory real obligations/data
before applying the same conclusion. D1 starts the replacement ledger empty;
it does not silently discharge an obligation found elsewhere.

| Area | Source evidence and remaining boundary |
| --- | --- |
| Accounts, menu, discounts, staff and revocation | [#348](https://github.com/larsbx/biz-kit/pull/348): prebound Biz-kit identities, scoped history, signed menu publishing, merchant-funded fixed discounts, staff sign-in and device revocation. D4–D6 are decided and implemented. |
| Fixed-route delivery | [#349](https://github.com/larsbx/biz-kit/pull/349)/[#378](https://github.com/larsbx/biz-kit/pull/378): Dispatch owns transport; distinct pickup/drop-off codes bind order and assignment. Delivery evidence grants no payment/settlement authority. |
| Restaurant-to-Dispatch acceptance | [#402](https://github.com/larsbx/biz-kit/pull/402) merged at `e358db60`, head `ed68dc92`: synthetic checkout/courier fixture, restart recovery and receipt replay. It is source-level acceptance, not observed deployment. The [November 16 local report](2026-11-16-eatsbot-402-local-acceptance.md) remains evidence of its own earlier revision. |
| Stack switch and legacy removal | [#426](https://github.com/larsbx/biz-kit/pull/426), merge `bc53e414`: legacy apps/release/config/unused dependencies removed; stack scripts serve `restaurant_host`. Its local rehearsal reports no listener on `:4100`. Running-host revision and health remain distinct evidence. |
| Standalone Fly source removal | [eatsbot #41](https://github.com/larsbx/eatsbot/pull/41), merge `fe649ff0`: main's Fly deploy/reset workflows and `fly.toml` removed. Default `dev` still carries old files. Cloud app/database disposition, token revocation and repository archival are not established by this merge. |

**Remaining operational evidence.** Use the
[retirement acceptance runbook](2026-11-23-retirement-cutover-acceptance.md#4-eatsbots-distinct-operational-remainder):
actual replacement revision/health; [Adder-ws host/tailnet acceptance](../adder-ws-cd.md)
before CD activation; Fly app/database disposition if present; obsolete token
revocation; restricted retention and read-only archival of `larsbx/eatsbot`.
Keep [issue #176](https://github.com/larsbx/biz-kit/issues/176) open for these
and the separately scoped marketing rounding-parity obligation. No step here
claims operational execution. Production delivery acceptance, when requested,
must separately demonstrate packaged services, outage/recovery and late pickup
after cancellation; the fixture alone does not establish those behaviors.

## Definition

Eatsbot is decommissioned when all four hold:

1. **Surfaces.** Every surface production Eatsbot serves is rehosted on a
   ledger-admitted host or dropped by a recorded owner decision (§1).
2. **Authority.** Each fact has one writer at every instant: legacy writes
   are stopped, queues drained and late outcomes reconciled (§2).
3. **Obligations and history.** Every open obligation has a named surviving
   owner, and retained history is inert audit data that grants no authority
   (§3).
4. **Repository and infrastructure.** The inactive umbrella apps, release,
   config and obsolete workflows are removed (done in #426); standalone
   deployment credentials/infrastructure are retired and `larsbx/eatsbot` is
   archived read-only after retention (remaining operational evidence).

The earlier Fly-production assumption is superseded by the November 16 owner
inventory. The [source divergence audit](2026-10-28-eatsbot-source-revision-audit.md)
still describes its pinned historical copies; it is not a current runtime
inventory. A successful CI or CD-trigger response does not observe a live host.

## 1. Surfaces to rehost or drop

The baseline column is historical. The requirement column records the owner
decisions now in force; it does not reopen them.

| Surface (umbrella copy) | Rebuilt at `89d5e8a2` | Requirement | Gate |
| --- | --- | --- | --- |
| Guest ordering and checkout | Storefront `/`: catalog menu, `Tax`/`Pricing`, cash at pickup, idempotent checkout key | Card payment only through Hawala; checkout stays financially unconfirmed until then | Slice 4 gate test passes against the deployed host; a card payment is settled by Hawala, never by an order step |
| Kitchen order lifecycle | Board `/board`: device-signed `RestaurantOrderStepV1`, pairing by secret | Staff sign-in, device grant revocation, cancellation reasons at the board | Revoked device's next event is refused; each retained step admitted by a signed event, with a refusal test |
| Menu, catalog, modifiers, availability | Menu from the restaurant file, static per boot; `CommerceCore.Catalog` has modifiers and availability | D6: keep editing without redeploy through signed catalog versions | Implemented in #348; preserve admission and version tests |
| Discounts and promotions | None at this baseline | D5: keep CommerceCore discounts; merchant-funded fixed amounts in the current host | Implemented in #348; retain pricing fixtures |
| Deliveries: `/deliveries`, `/map`, `DeliveryAuthPlug` bearer keys, public tracking | Not built (slice 5). Kitchen workflow has `dispatched`, delivery-owned | `DispatchCore` policy, `FulfillmentCore` handoff, `apps/dispatch` as the one transport writer | A delivery order reaches `completed` only on Dispatch-owned proof; no bearer key or GPS proximity counts as proof |
| Customer accounts: AshAuthentication `/auth` (password, magic link) | None at this baseline | D4: keep accounts through `biz_kit_identity`; old auth state is not imported. Never merge principals on name/email | Implemented in #348 |
| GraphQL `/gql` | None | D3: dropped | Any real external consumer found outside the empty test stack is repointed or told |
| AshAdmin `/admin` (basic auth, `ADMIN_API_KEY`) | Governance grants via `mix restaurant.grant` | Drop. The implicit admin bypass does not migrate | Not served by any retained host |
| Telegram bot: webhook, notifier, ordering chains, marketing, QR/NFC touchpoints | None | D2: dropped; generic marketing/consent policy remains in its cores | Any registered webhook/token outside the empty test stack is retired; preserve applicable suppressions (§3) |
| Kafka producer | None | R0 found a Noop driver and no consumer on the test stack | Source removed with legacy runtime; any other deployment needs its own inventory |
| Prometheus metrics | None | Shared infrastructure, when a second consumer needs it | Decided and recorded |

## 2. Authority cutover

| Condition | Current disposition | Gate |
| --- | --- | --- |
| Rebuilt admission | `RestaurantCore.Admission` refines the kitchen reducer; the Log admits orders and steps from granted devices only | Holds on the deployed host |
| Legacy order and checkout semantics | 48 recorded successes kept, 459 unauthorized requests refused, 207 typed refusals (`order_actions`, pinned to `eatsbot@15a201e`) | Holds |
| Legacy state carried over | D1: start empty; no migration. The confirmed disposable stack has no customer data to archive | For any other actual copy, retain required history and finish/assign outstanding obligations (§3). No legacy row grants ledger authority |
| Single writer | #426 removes the legacy runtime from the disposable stack; it no longer creates the old database | Observe the actual deployed revision and absence of old services/listeners. Trigger fencing is not the selected mechanism for a database recreated on every old start |
| Drain | Owner confirmed no customer data and no drain needed on `adder-ws` | Inventory and reconcile real callbacks/obligations if another legacy copy is found |
| Recovery | Preserve the replacement's accepted events; do not restart an obsolete writer as an automatic fallback | Host acceptance records recovery against the actual deployment |

## 3. Obligations and history

None of it converts into ledger authorization. These retention obligations
apply to real retained data/obligations found in an inventory. The owner-confirmed
empty disposable stack requires neither a database archive nor a backlog drain.

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

| Package | Current source status | Remaining |
| --- | --- | --- |
| R0 baseline and freeze | November 16 inventory and owner-confirmed disposable test stack, landed in #426 | Live-host observation is distinct; inventory any other actual legacy copy |
| R1 characterization | Seven fixture families pinned: orders, checkout, coupling, pricing, delivery | Marketing attribution Money rounding parity |
| R2 pure cores | Retained rules extracted; D5 discounts included | Further consumers need their own authority and conformance acceptance |
| R3 host and admission | #348 and #349/#378 implement the selected replacement | Production acceptance is specific to the deployed host and retained workflow |
| R4 parallel proof | D1 starts empty; no test-stack data migration; #402 adds delivery fixture acceptance | Actual production/packaged evidence is not implied by the fixture |
| R5 switch and drain | Approved stack source switch in #426; no test-stack drain required | Observe actual host revision and complete host/CD acceptance |
| R6 retire | Legacy umbrella apps removed in #426; main's Fly machinery removed in eatsbot #41 | Cloud app/database disposition, token revocation, source repository archival |

## Open

Keep the current table and [issue #176](https://github.com/larsbx/biz-kit/issues/176)
aligned. Marketing rounding parity remains a generic capability obligation;
there is no surviving Telegram channel that turns it into a legacy-runtime
retention requirement. Record host/infrastructure observations separately from
merged source and synthetic acceptance.

## Migration status as of November 14, 2026

Historical link anchor retained for the November 16 acceptance report. The
November 14 snapshot is preserved in
[the earlier checklist revision](https://github.com/larsbx/biz-kit/blob/1f3a9ac7f1480ecb5575fe4748920b0cb477aa4a/docs/architecture/2026-11-07-eatsbot-decommission.md#migration-status-as-of-november-14-2026).
Use the November 23 retirement status above for current gates and decisions.
