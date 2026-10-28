# Eatsbot salvage and verified retirement plan

Date: 2026-10-28. Status: **Proposed target architecture; inventory and retirement plan, not a production shutdown**.
Paired with [the cross-repository extension ADR](2026-10-28-cross-repository-extension-and-hawala-capability.md) (biz-kit PR #175) and the [Eatsbot retirement ADR](https://github.com/larsbx/eatsbot/blob/dev/docs/modules/decisions/pages/biz-kit-interoperability-and-source-ownership.adoc) (eatsbot PR #35).

## Decision and end state

**Decommission Eatsbot as an independently maintained product and application. Salvage reusable code, tests, contracts, and domain semantics into the canonical biz-kit capabilities; leave no permanent active duplicate Eatsbot writer or runtime.** This supersedes the earlier idea that Eatsbot should remain a permanently independent first-class product.

The existing Eatsbot repository (`larsbx/eatsbot`, default branch `dev`) and imported copies under `apps/eatsbot*` are **temporary source and compatibility assets**. Production source/writer authority remains with the current deployment **only until proven and explicitly authorized cutover**. This ADR does not order a deployment shutdown, switch any database writer, or authorize a destructive purge. After approved cutover and a defined rollback/retention window, archive Eatsbot as read-only provenance, rather than delete its history.

The platform must gain generic capabilities without forcing restaurant labels, Telegram IDs, Eatsbot DB schemas or trust assumptions into other applications. Use source-attributed, independently tested *extraction* rather than a whole-app copy.

## Salvage allocation: current repository files inspected

| Legacy source (under `apps/eatsbot_core/lib/`) | Destination | Reuse plan / constraint |
| --- | --- | --- |
| `marketing/attribution.ex` | **new `apps/marketing_core`** | Pure notification-to-check-in attribution window, one-attribution-per-notification guard, Money/Decimal commission calculations, redemption window and code generation; generalize source/campaign/merchant identifiers and add rounding/boundary tests. |
| `marketing/touchpoint.ex`, `marketing/visit.ex`, `marketing/visit/check_in.ex` | MarketingCore policy + biz-kit host | Extract QR/NFC touchpoint, check-in, attributed conversion, redemption, rate snapshot and evidence rules; do **not** copy Eatsbot.Ash/Postgres tables or assume a scan grants promotion consent. |
| `marketing/promotion.ex` | MarketingCore | Promotions, validity, branch/merchant scoping and campaign lifecycle; replace bulk timestamp stamping with confirmed, auditable delivery evidence. |
| `marketing/subscriber.ex`, `marketing/consent_bridge.ex` | **existing `sales_core`** + channel adapter | Consent and withdrawal remain SalesCore's default-deny authority. Existing Telegram `:subscribed` records do not constitute independently evidenced cross-domain opt-in; carry suppressions forward, not inferred grants. |
| `products/discount_rule.ex`, `carts/discounts_calculation.ex` | **existing `commerce_core`** | Candidate percentage/fixed/bundle pricing rules and test fixtures; audit quantity guards, precision, currency context and time-of-day semantics before extraction. MarketingCore may reference eligible offers; CommerceCore prices them. |
| `brands/brand.ex`, `brands/branch.ex`, `products/*` | CommerceCore/catalog host where useful | Merchant/site/catalog/variant/option patterns and compatibility fixtures; remove Eatsbot-specific schema/authorization, preserve source merchant ownership. Do not duplicate CommerceCore's already extracted pricing and catalog projection. |
| `carts/checkout.ex`, `orders/order.ex`, `orders/transitions.ex` | CommerceCore and domain adapters | Cart-lock, idempotent checkout, immutable order-price snapshot, transition relation and replay tests. Extract shared rules only; restaurant kitchen choices are optional domain profiles, not a universal order lifecycle. |
| `orders/delivery_coupling.ex`, `orders/sync_from_delivery.ex` | **existing `fulfillment_core`** | Extract the *single-owner* order/transport edge invariant and conformance tests. Do not import same-database mirrored writes or two cross-service authoritative writers. |
| `deliveries/transitions.ex`, `deliveries/delivery_state_changes.ex`, `deliveries/update_history.ex` | **new pure `apps/dispatch_core`** | Last-mile lifecycle and auditable state transitions. Dispatch's deployed `apps/dispatch` remains the transport authority; reuse the existing FulfillmentCore handoff, not a third state writer. |
| `deliveries/delivery.ex`, `deliveries/stale_cleaner.ex` | DispatchCore policy + Dispatch app/TaskCore host | Delivery evidence types, exception and timeout classification, terminal recovery. Do **not** promote legacy bearer delivery keys, unverified GPS proximity or timed-out deliveries into authorization, completed proof or irreversible failure. |
| `apps/eatsbot_extension_telegram_bot/lib/*` | Optional communications/channel adapter | Harvest authenticated webhook parsing, formatting and opt-out semantics; deliver from a durable consent-rechecked outbox, not unconfirmed direct PubSub callbacks. Do not place Telegex/Telegram dependency in pure MarketingCore or DispatchCore. |
| `apps/eatsbot/lib/eatsbot_web/live/*` and GraphQL/LiveView | Reusable UX patterns only | Adapt tracking, status and dashboards to existing Dispatch/commerce contracts. No separate Eatsbot web runtime kept just for templates. |
| Kafka, Prometheus and telemetry adapters | Shared infrastructure only when a second consumer needs them | Reuse verified producer/supervision and observability tests without maintaining `eatsbot_extension_*` packages indefinitely. Follow current KafkaEx integration contracts; do not duplicate event delivery authority. |

The table is a **code audit candidate map**, not a declaration that every item passes extraction. Confirm each file's upstream revision and tests before moving it. Existing general-purpose kernels `commerce_core`, `sales_core`, `fulfillment_core`, `inventory_core`, `task_core` and the real Dispatch backend remain canonical.

### Strict ownership rules

- **MarketingCore** owns pure campaign, touchpoint, attribution, redemption and commission-policy calculations. It **does not** own marketing-consent authority (SalesCore), pricing (CommerceCore), sender credentials, persisted customer PII, or cash transfers (Hawala/external regulated provider).
- **DispatchCore** owns reusable delivery/last-mile policy; **`apps/dispatch`** owns live transport records, scoped grants, driver and location observations, dispatch API and physical proof validation. **FulfillmentCore** owns cross-domain commercial-to-transport handoff and cancellation races.
- **Eatsbot-specific kitchen semantics**, if useful, become an optional restaurant domain/profile within biz-kit only after a consumer is identified. If there is no future consumer, preserve tests/docs in the archive and drop the runtime rather than manufacture a permanent package.
- Keep marketing QR/NFC touchpoints **separate** from Hawala's exclusive QR participant-identity presentation and signed financial consent. Neither attribution nor an order `Committed(intent)` constitutes payment finality.
- Do not migrate legacy bearer tokens, implicit admin bypass, subscriber `:subscribed` flags, location floats, or PubSub send-before-confirm patterns as platform security or evidence authority.

## Pinned first-source audit

[The read-only revision comparison](2026-10-28-eatsbot-source-revision-audit.md)
records exact biz-kit and standalone Eatsbot source commits and 15 checked modules.
The differing blobs must be reconciled against source tests before an authority
migration. This is **not** a production database or active-obligation inventory.

## First implementation slices (proposed, not production admission)

- [MarketingCore extraction PR #177](https://github.com/larsbx/biz-kit/pull/177): no-dependency portable attribution/engagement-code and one-use redemption candidates. Strengthens attribution to confirmed message delivery; historical Money rounding parity remains unproven.
- [DispatchCore extraction PR #178](https://github.com/larsbx/biz-kit/pull/178): 13 legacy transition edges characterized plus portable proof/cancellation/uncertainty candidate policy. This is **not** a substitute for the operational Dispatch writer or FulfillmentCore's existing handoff.

Both represent early R1/R2 development; the legacy authoritative writers, migrations and R3–R6 cutover remain unchanged.

### First host-only composition candidates (stacked PRs)

- [MarketingBridge #179](https://github.com/larsbx/biz-kit/pull/179), stacked on #177: combines current SalesCore consent, versioned tenant/party/campaign scope and a host-verified delivery receipt binding with MarketingCore attribution. Pure unsigned preflight, not authenticated sender or durable admission.
- [LastMileBridge #180](https://github.com/larsbx/biz-kit/pull/180), stacked on #178: proposes FulfillmentCore handoffs only when merchant/transport/source/proof bindings match. The actual Dispatch/Fulfillment authorities and any uncertain cancellation/delivery remain independent; pending cancellation is a reconciliation blocker.

Both are staged R3 **contract composition only**. They have no live host signatures, current-grant rechecks at append, actual ledger writes, durable queues or production traffic cutover. Their shared `biz_kit_composition/mix.exs` additions must be reconciled after the parent core PRs merge.


## Decommission work packages (each separately reviewed)

**R0 — Baseline and freeze.** Record exact standalone `dev` commit, imported-copy commit(s), current deployments, DNS/webhooks, clients, databases, schemas, secrets, third-party APIs, queues, CI, active orders/deliveries/subscribers/obligations, privacy/retention rules and archive/legal needs. Add a dual-source divergence diff: the current imported and standalone copies have some differing files, so do not assume an identical tree. Freeze **new** legacy-product features once an operational freeze is approved, except fixes required for safety, contractual commitments and security.

**R1 — Characterization/conformance.** Pin legacy outputs, error forms and edge cases in tests before extraction. Require independent compilation of new pure packages outside the umbrella, property/replay tests and a second nonrestaurant consumer. Marketing cases include attributed/unattributed visits, withdrawn consent, duplicate redemption, commission rounding and lost delivery acknowledgments. Dispatch cases include cancellation versus delivered evidence, authority on each transition, stale/replayed updates, lost acknowledgment and concurrent retries.

**R2 — Extract shared pure cores.** Implement `marketing_core` and `dispatch_core` by moving/generalizing pure policies; delegate legacy calls temporarily for parity. Do not copy Ash persistence, Eatsbot identity, direct bot sends or business writers. Extend existing CommerceCore, SalesCore, FulfillmentCore and TaskCore where each already owns the invariant.

**R3 — Platform-authoritative adapters.** Add BizKit.ExtensionV1 manifests/contracts and domain adapters to existing platform admissions. Provide persistent outbox/inbox, atomic local append, exact idempotency and source-attributed projections; no dual authoritative writer. Route any payments through separately verified financial interfaces and authority, never marketing commission statements.

**R4 — State migration and parallel proof.** Reconcile every relevant legacy order, marketing consent and suppression, redemption, delivery, payment/refund/commission liability, and audit record at an explicit cutoff and version. Use read-only shadow projections and signed comparison reports, **not** dual writes. Cover incomplete operations and unknown effects; retain `HOLD` where a result cannot be proved. Validate new host against actual external consumers and failure/restart/partition cases. Document data migration, de-duplication, retained history, encryption, retention and rollback checkpoints.

**R5 — Authorized switch and drain.** Only after green revision-pinned release, integration, load, authorization and migration acceptance: approve the writer/traffic cutover, stop legacy writes, drain callbacks/jobs/queues, reconcile late receipts, and repoint every external endpoint/client. Keep a controlled rollback window and record the one authoritative owner at each instant. No data or financial obligation may be silently orphaned.

**R6 — Retire the product.** Remove `eatsbot`, `eatsbot_core` and legacy `eatsbot_extension_*` packages from active biz-kit releases/dependency graphs **after** all surviving capabilities have consumers, history and tests elsewhere. Disable standalone deployment and automated production deploys; revoke only obsolete service credentials, migrate/close channel integrations and decommission infrastructure after retention and contractual obligations are satisfied. Archive `larsbx/eatsbot` read-only with commit history, migration mappings and provenance (not delete or publicly expose sensitive data). Mark documentation explicitly retired.

## Required acceptance evidence / exit checklist

- [ ] Complete source-dependency and live-client inventory; exact immutable source/release versions pinned.
- [ ] Every retained capability has a new canonical code owner, test suite and consumer contract; unused parts explicitly marked discarded.
- [ ] Marketing opt-outs survive migration, old opt-ins are **not** silently elevated, and attribution uses evidenced delivery/check-in/redemption.
- [ ] Delivery roles, signed source proofs, cancellation races, idempotency and unknown-outcome `HOLD` behavior pass negative and restart tests.
- [ ] No simultaneous authoritative writers; migrated order/customer/contact/commission/delivery state reconciles with signed/retained audit history.
- [ ] All active obligations (refunds, customer funds, gift cards, unredeemed promotions, chargebacks, commissions and partner commitments) have a named surviving owner and resolution route.
- [ ] Current production endpoints/consumers are verified on replacement implementations, with deployment rollback and privacy/security review.
- [ ] Only then the legacy service is disabled, deprecated packages removed and the repository archived under approved retention.

**This document is a planned decommission, not proof of a completed decommission.** None of the numbered phases is established as passed merely by merging this ADR.
