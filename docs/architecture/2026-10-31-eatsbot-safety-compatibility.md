# Eatsbot order and checkout safety compatibility — 2026-10-31

Status: independently tested pure R1/R2c candidates. No live writer integration
or retirement. [Issue #176](https://github.com/larsbx/biz-kit/issues/176) remains
open. Eatsbot #37 and biz-kit #217 have merged; their immutable fixture baseline
is preserved, including defects.

## Provenance and comparison scope

Source: `larsbx/eatsbot@15a201ee1279bffce09ab200609c2490f219af8c`,
`eatsbot/test/fixtures/characterization/`. Each copied file is byte-for-byte
pinned with SHA-256 and a record count in the consuming test. Checkout input
scenarios are reconstructed from that same commit's
`test/characterization/orders_characterization_test.exs`, rather than using
the golden outputs to supply expected input prices.

| Fixture | Records | SHA-256 | Comparison |
| --- | ---: | --- | --- |
| order_transitions | 192 | `ab0005bbb716b2b9eee626e90128099e3ff5d9d2e562123cd6f85f0c72e328de` | Full legal/illegal relation; unknown fulfillment additionally refuses |
| order_lifecycle | 38 | `0845114f2021f0d12879a822477af452f1d965517d9a9473abe21e96d0174240` | Initial/terminal states, next states and all 13 mathematical replay histories |
| order_actions | 714 | `c739be36e2c6136077a6e3dd81d242ed2d7fd7189705a4fbcfac680e9e935d26` | Reachability paths, successful next states, operation-role policy and explicit refusal mapping |
| checkout | 11 | `75ab2f968d726b2cdb570490072a5bff4829e92bfca1ec4427ef16b88c3465f8` | Commercial snapshots, prices, cart completion, delivery-request cardinality, repeats and refusal reasons |

The companion FulfillmentCore coupling tests cover all 307 coupling records;
see its README for the independent package and exact safety differences.
Pricing's 314 and DispatchCore's 132 legacy-delivery records remain under
their existing tests. Coverage of all seven fixture families does **not** mean
full database/adapter/production parity.

## Intentional differences from legacy behavior

1. Authorization first. A host supplies a verified grant bound to merchant,
   order, principal, actor class and explicit allowed actions. Checkout context
   must name `operation: :checkout`; unrelated grants cannot be reused. Denied operations return exactly
   `{:error, :forbidden}` before examining state, history, revision or duplicate
   outcomes. Actor names or a request-provided boolean are not authentication.
   Public tracking is outside these command reducers.
2. The actual pinned action file contains **48 successes and 666 refusals**:
   90 forbidden, 570 transition-validation errors and six delivery-ownership
   validation errors. The earlier PR summary's 54/660 counts are not the pinned
   data. Of the 570 transition errors, **369** concern actor classes that cannot
   perform the requested action. The 714-case comparison preserves all 48
   successful next states; all 459 unauthorized requests now uniformly refuse.
   The other 207 refusals are typed invalid-transition or delivery-owned errors.
   No Ash error class/message compatibility is promised by the pure reducers.
3. Administrators cannot take delivery-owned dispatch/completion/failure through
   order commands. FulfillmentCore/Dispatch ownership is independent of kitchen
   authority. No caller-selectable synchronization flag bypasses this rule.
4. Accepted command IDs bind the full command, principal and actor. Identical
   retries return the current projection without repeating a transition; changed
   payloads/principals conflict. Current authorization is required even for
   retries. Commercial line/total snapshots survive lifecycle commands unchanged.
   Mathematical replay checks continuity and legal edges, not signature provenance.
5. Checkout retries retain the first immutable order and prices, including the
   recorded delivery retry that omits its original fee/tip. New keys cannot reuse
   a completed cart, even in another channel. A key used by another cart refuses;
   another principal receives no prior order or collision details. Merchant
   projections are separate. Malformed adjustment/delivery requests refuse.
6. The pure checkout candidate has a delivery-request marker instead of a live
   Delivery row/public authentication key, and creates no tracking key. Tests
   compare commercial fields and the required delivery cardinality, not generated
   keys or database effects. These remain explicit R3/R4 adapter obligations.
7. Checkout intent is always financially unconfirmed. Client settlement fields
   are ignored. Lifecycle completion, cancellation and `Tax.reverse/4` do not
   create settlement or refund acceptance. The canonical TigerBeetle-first
   architecture through Hawala remains the prerequisite for financial acceptance;
   PostgreSQL/history persistence and derived projections follow the confirmed
   operation. Neither new module exposes a competing financial writer.

## Reproduction and evidence

On the repository's supported Elixir 1.19.0 / OTP 27.3.4 toolchain:

```sh
cd apps/commerce_core
MIX_ENV=test mix compile --warnings-as-errors
mix test --no-start --seed 0
```

Repeat from `apps/fulfillment_core` for the companion coupling package. The
existing portable OTP 26 workflow also consumes both packages independently.
New source/tests are included in the focused formatting workflows.

Local standalone runs: CommerceCore **45 tests plus seven properties**, and
FulfillmentCore **17 tests**, zero failures; strict core compilation and formatting
pass. Hex registry access failed in this execution environment, so standalone
test projects used local path dependencies extracted from upstream Hex archives,
each verified against the repository lockfile's outer SHA-256. Package source,
test source and production Mix dependency declarations were unchanged; the
scratch-only path overrides are not repository changes. This evidence is not
a full umbrella acceptance or a hosted exact-head CI result.

Negative controls deliberately remove authorization, merchant/order binding,
delivery ownership, principal binding, cart reuse protection, checkout ownership,
or assert financial settlement; each must fail the safety tests. Fixture edits
must fail the hash pin. Companion controls remove coupling ownership/source checks.
These are fault injections in isolated test copies, not changes to golden files.

## R0–R6 remain separate obligations

| Gate | Remaining obligation |
| --- | --- |
| R0 | Exact deployment/database/release/consumer/PII/open-liability inventory and feature freeze |
| R1 | This adds five missing fixture families and explicit defect mapping; it does not complete every donor capability's characterization |
| R2 | These are existing CommerceCore/FulfillmentCore slices; independently verify remaining MarketingCore/DispatchCore/catalog/discount consumers |
| R3 | Authenticate grants and source facts; prove host refinement; atomically serialize cart/order/coupling/outbox/inbox; durable idempotency and no server-signed participant financial consent |
| R4 | Deterministic migration/replay against real consumers, unresolved order/refund/promotion/commission reconciliation, audit/privacy retention and rollback |
| R5 | Separately approved single-writer cutover, webhook/queue drain, pending-outcome reconciliation and release acceptance |
| R6 | Remove legacy runtime/releases/dependencies and archive only after all cutover, retention and external obligations are satisfied |

No gate is closed by these tests alone. No production traffic, legacy resource,
live transport authority, financial ledger, deployment or runtime is changed.
