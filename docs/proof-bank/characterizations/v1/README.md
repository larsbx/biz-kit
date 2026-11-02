# Biz-kit application characterizations — audited baseline v1

Source revision: `a98489111a74b395e97f797f0b21e7f53cd95997` (draft stacked PR #241). This is a **static source/test evidence audit**, not a proof or passed application conformance run. Every entry in [catalog.json](../../../../proof_bank/characterizations/v1/catalog.json) is unreviewed, unproven, and unexecuted.

## Evidence levels

1. **Intent:** documented purpose and user-facing behavior, still subject to domain-owner interview/approval.
2. **Implementation observation:** source files checked at an exact SHA. Presence is *not* behavior correctness.
3. **Existing tests:** app-local test file inspection. No test is marked passing until exact SHA execution and exit status are captured.
4. **Behavior conformance:** run tests, adversarial counterexamples, concurrency/race cases, external dependencies and independent oracles.
5. **Formal verification:** formalize only a reviewed behavioral contract; bind precise assumptions, proof checker version, implementation refinement, and deployed authority.

**Do not infer conformance from a model file, an app folder, a coverage percentage, a test filename, or a CI job in queued status.**

## All application characterizations

| Component | Intended feature family | Implementation lead | Test lead | First formal obligation | Status |
| --- | --- | --- | --- | --- | --- |
| `biz-kit` | Umbrella of composable business domains, with signed admission and extension governance | [source](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/mix.exs) | **no app-local case** | Every business effect passes exactly its owner’s authenticated admission path | **Unverified** |
| `agent_core` | Agent-neutral profiles, launch/poll/cancel ports, preflight | [source](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/agent_core/lib/agent_core/profiles.ex) | [test](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/agent_core/test/profiles_test.exs) | Only current approved profile revisions may launch runs | **Unverified** |
| `agent_ops_store` | Agent coordinator, tool proxy, workers, event replay and durable cursor | [source](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/agent_ops_store/lib/agent_ops_store/coordinator.ex) | [test](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/agent_ops_store/test/coordinator_test.exs) | Stale agent leases cannot admit competing business effects | **Unverified** |
| `barter_core` | Exact multi-party intent matching, consortium brokerage and exchange previews | [source](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/barter_core/lib/barter_core/optimizer.ex) | [test](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/barter_core/test/barter_core_test.exs) | An optimizer preview cannot transfer assets without separately signed admission | **Unverified** |
| `biz_kit_cluster` | Distributed singleton ownership, failover and recovery after partitions | [source](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/biz_kit_cluster/lib/biz_kit/cluster/singleton.ex) | [test](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/biz_kit_cluster/test/singleton_test.exs) | After partition recovery at most one fenced authority may perform effects | **Unverified** |
| `biz_kit_composition` | Pure catalog/stock/price/fulfillment and marketing candidate previews | [source](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/biz_kit_composition/lib/biz_kit/composition.ex) | [test](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/biz_kit_composition/test/composition_test.exs) | A preview never implies a committed reservation, sale or delivery | **Unverified** |
| `biz_kit_extension` | Portable ExtensionV1 manifest validation, dependency ordering, inert activation planning | [source](https://github.com/larsbx/biz-kit/blob/a98489111a74b395e97f797f0b21e7f53cd95997/apps/biz_kit_extension/lib/biz_kit/extension/manifest.ex) | [test](https://github.com/larsbx/biz-kit/blob/a98489111a74b395e97f797f0b21e7f53cd95997/apps/biz_kit_extension/test/manifest_test.exs) | Extension planning must never confer grants or execute arbitrary code. | **Unverified** |
| `biz_kit_identity` | Principals, provider binding, persistent native sessions and revocation | [source](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/biz_kit_identity/lib/biz_kit/identity/sessions.ex) | [test](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/biz_kit_identity/test/durable_sessions_test.exs) | Revoked principal cannot act through persisted sessions | **Unverified** |
| `commerce_core` | Exact Money-valued pricing, rounded tax, catalog and checkout proposals | [source](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/commerce_core/lib/commerce_core/pricing.ex) | [test](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/commerce_core/test/checkout_safety_test.exs) | Currency totals and tax component shares conserve exact minor units | **Unverified** |
| `coop_substrate` | Canonical signed append-only business-event ledger, replay and custody | [source](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/coop_substrate/lib/coop_substrate/canonical.ex) | [test](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/coop_substrate/test/canonical_test.exs) | Accepted append always binds canonical bytes, authorization, scope and replay identity | **Unverified** |
| `dispatch` | Ash/Phoenix transport authority: scoped roles, fleet, operations board, devices and status events | [source](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/dispatch/lib/dispatch/access.ex) | [test](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/dispatch/test/dispatch/operations/board_concurrency_test.exs) | Concurrent authenticated assignments cannot create active driver/vehicle conflicts | **Unverified** |
| `dispatch_core` | Pure last-mile states, producer evidence, cancellation and legacy edge characterization | [source](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/dispatch_core/lib/dispatch_core/last_mile.ex) | [test](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/dispatch_core/test/dispatch_core_test.exs) | Cancellation cannot fabricate or erase confirmed physical transport facts | **Unverified** |
| `eatsbot` | Legacy Phoenix restaurant orders, carts, deliveries and marketing | [source](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/eatsbot/lib/eatsbot.ex) | [test](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/eatsbot/test/eatsbot/orders/checkout_concurrency_test.exs) | Retirement preserves accepted order/delivery history without a competing writer | **Unverified** |
| `eatsbot_core` | Legacy Ash products/variants/options, carts, orders and deliveries | [source](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/eatsbot_core/lib/products/product.ex) | [test](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/eatsbot_core/test/core_test.exs) | Preserve legacy commerce behavior under independent replay characterization | **Unverified** |
| `eatsbot_extension_kafka` | Kafka publication, ack mapping and refusal of ambiguous retry outcomes | [source](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/eatsbot_extension_kafka/lib/driver.ex) | [test](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/eatsbot_extension_kafka/test/driver_test.exs) | Ambiguous publish outcomes cannot be recorded as acknowledged success | **Unverified** |
| `eatsbot_extension_prometheus` | PromEx metrics instrumentation and legacy supervisor endpoint | [source](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/eatsbot_extension_prometheus/lib/extension.ex) | **no app-local case** | Monitoring does not disclose private records or confer commands | **Unverified** |
| `eatsbot_extension_telegram_bot` | Telegram webhook/controller, conversation chains, legacy marketing bridge | [source](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/eatsbot_extension_telegram_bot/lib/controller.ex) | **no app-local case** | Unverified Telegram messages cannot authorize business effects | **Unverified** |
| `federation_core` | Pure ActivityStreams marketplace and pending subscription wire contracts | [source](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/federation_core/lib/federation_core/marketplace.ex) | [test](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/federation_core/test/marketplace_test.exs) | Untrusted remote listings can never become local business authority | **Unverified** |
| `federation_service` | Read-only HTTPS explicit-peer discovery, inbox signature checking and durable projection | [source](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/federation_service/lib/federation_service/inbox.ex) | [test](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/federation_service/test/network_test.exs) | Stale/withdrawn listings cannot be resurrected through reorder/retry | **Unverified** |
| `fulfillment_core` | Pure commerce-to-transport request, accept/reject, cancellation and proof protocol | [source](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/fulfillment_core/lib/fulfillment_core.ex) | [test](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/fulfillment_core/test/fulfillment_core_test.exs) | Cancellation race cannot invent completed cancellation or erase delivery fact | **Unverified** |
| `group_buy_core` | Member pledges, volume-tier group purchases, binding threshold and escrow-shape previews | [source](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/group_buy_core/lib/group_buy_core/binding_round.ex) | [test](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/group_buy_core/test/binding_round_test.exs) | Pledges bind exactly once on threshold, distinct from stock and money movement | **Unverified** |
| `hawala_capability` | Test-only external Hawala cross-authority replay, journal failure and signed test-port contracts | [source](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/hawala_capability/test/support/cross_authority_host.ex) | [test](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/hawala_capability/test/conformance_test.exs) | Test receipts must never be treated as live financial settlement | **Unverified** |
| `inventory_core` | Pure receipt/reservation/release/transfer policy, menu availability and basket preflight | [source](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/inventory_core/lib/inventory_core.ex) | [test](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/inventory_core/test/inventory_core_test.exs) | All accepted holds respect nonnegative available stock under concurrency | **Unverified** |
| `keel` | Temporal organization/ownership/roles, exact decision quorums and invariant checks | [source](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/keel/lib/keel/invariants.ex) | [test](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/keel/test/conformance_test.exs) | Invalid/cyclic temporal ownership cannot grant active permissions | **Unverified** |
| `marketing_core` | Pure confirmed-delivery attribution, touchpoint QR and one-use redemption | [source](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/marketing_core/lib/marketing_core/attribution.ex) | [test](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/marketing_core/test/marketing_core_test.exs) | Only authenticated timely delivery can qualify for attribution | **Unverified** |
| `proof_bank_core` | Strict interview→requirement→obligation traceability and independent engine ports | [source](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/proof_bank_core/lib/proof_bank_core.ex) | [test](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/proof_bank_core/test/proof_bank_core_test.exs) | Generated candidate cannot promote its own proof, approval or extension activation | **Unverified** |
| `sales_core` | Pure CRM pipeline, scoped marketing consent, revocation and candidate audience planning | [source](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/sales_core/lib/sales_core/consent.ex) | [test](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/sales_core/test/sales_core_test.exs) | Withdrawal prevents subsequent marketing including stale regrant/replay | **Unverified** |
| `school_ops` | Grade 2 curriculum catalog and place-value staff readiness TaskCore proposals | [source](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/school_ops/lib/school_ops/catalog.ex) | [test](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/school_ops/test/domain_test.exs) | Staff readiness tasks never assert learner mastery or authoritative assessment results | **Unverified** |
| `spruce_goose` | Postgres/Ash operational orchestration with actor grants, CLI authority and recovery markers | [source](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/spruce_goose/lib/spruce_goose/actors.ex) | [test](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/spruce_goose/test/authority_runtime_test.exs) | After delegated cutover no secondary privileged direct writer can operate | **Unverified** |
| `task_core` | Pure task DAG, lifecycle/DoD/evidence, and signed agent-intent logic | [source](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/task_core/lib/task_core/admission.ex) | [test](https://github.com/larsbx/biz-kit/blob/e9388efeacd07882357889f110c5e642b2fae6ed/apps/task_core/test/agent_runs_test.exs) | Revoked grants or changed task versions invalidate runnable agent intents | **Unverified** |

## Early audit findings

**EatsbotCore:** The only app-local ExUnit case calls `Core.hello()` but the application tree has no corresponding `Core` module source. This is a concrete *test-suite relevance gap* (and a plausible failing test), **not** a demonstrated runtime regression. Characterize the real Ash resources using `eatsbot` and extracted portable-core consumers before changing ownership.

**Eatsbot Prometheus and Telegram:** No `*_test.exs` cases in their own app test trees (only helpers and support handlers). Implement negative security/ingress cases before claiming conformance.

**HawalaCapability:** Source README explicitly specifies a **test-only** adapter and immutable external Hawala fixtures. No live financial gateway exists here. Cross-VM fencing and financial finality are outside the scope of the test harness.

**GroupBuyCore:** The current rule is *binding when admitted threshold is reached* without a second member purchase election. Distinguish binding buyer obligations from reservation, payment and settlement; older generic seed text should be reconciled.

**SpruceGoose:** This app currently describes an authoritative operational orchestration control plane with explicit delegated/cutover state. Treat as a transitional authority, not a harmless retired library.

**SchoolOps:** Existing domain here ships the first Grade 2 course and staff TaskCore proposals; K–12 completeness and learner mastery are not established.

**Conformance:** At review time PR #236/#241 workflow runs were queued. No exact-revision test outcomes, independent formal proofs, or production admission checks have been established in this audit.

## Formal layers, derived from real app semantics

| Layer | Proof target | Required evidence | Applications |
| --- | --- | --- | --- |
| L0 | Approved requirements, factual assumptions, explicit domain vocabulary | Domain-owner interview, source revision, counterexamples | All |
| L1 | Pure functional identities, normalization and exact arithmetic | Golden fixtures, property tests, Lean for supported identities | Commerce, CoopSubstrate, Barter, Inventory |
| L2 | State transition preservation | Exact state + transition relation, induction and test refinement | TaskCore, GroupBuy, Fulfillment, Sales, AgentCore |
| L3 | Concurrency and distributed histories | Quint bounded exploration clearly labeled bounded, retry/fault injection, liveness assumptions | Cluster, AgentOpsStore, Kafka, Federation |
| L4 | Host-to-model authority refinement | Exact-head DB/integration/browser tests, admission replay, signatures, crash recovery | Dispatch, Inventory host, SpruceGoose, Hawala host |
| L5 | Artifact/release/marketplace safety | Signed immutable builds, dependency and grant gates, rollback and revocation | All deployables |

Lean proof of an abstract model does **not** verify its Elixir implementation. Bounded Quint traces do **not** prove universal behavior. A verified source contract does **not** establish the freshness or authenticity of live business data.

## Acceptance sequence

Reconcile P0 business authority and current app behavior, prioritize a pure InventoryCore reservation invariant plus concurrent Dispatch authority as two unlike pilot domains, and map every relevant test to the modeled rule. Require exact-head test runs and evidence of host refinement. Keep unverified or contradictory requirements as explicit blocking findings. Promote no third-party extension to marketplace until these first-party gates are accepted.

Machine audit: `python3 scripts/proof_bank_characterization_audit.py`; the script only checks catalog/source integrity, **not correctness of applications**.

## Executable conformance probe lane

A separate GitHub Actions matrix runs existing `mix test --no-start --trace`
for 12 pure policy/portable apps at the exact checked-out PR revision.
This lane is **behavioral regression evidence**, not a Lean proof or a
verification of the live host, its DB migrations, external signatures or
side effects. CI must show passing jobs and captured log links before a
reviewer changes any `not_executed` catalog state. The current catalog
remains deliberately pessimistic even after tests are scheduled.

Hosts (`dispatch`, `spruce_goose`, `eatsbot`, `federation_service`),
remaining app/test fixtures, external `hawala-core` and the two legacy
Eatsbot extensions with no app-local ExUnit cases require separate
infrastructure-specific acceptance gates. The pure-core lane cannot
substitute for those tests.
