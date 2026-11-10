# Procurement through the actual Dispatch worker

## Scope and current acceptance

This continuation tests the procurement handoff through the existing Dispatch
worker, authorized assignment operations and courier portal/receipt path. It is
stacked on [PR #354](https://github.com/larsbx/biz-kit/pull/354), including the
signer-count correction from
[PR #353](https://github.com/larsbx/biz-kit/pull/353), and reuses the delivery
integration introduced by
[PR #349](https://github.com/larsbx/biz-kit/pull/349).

**Execution results:** the observed runs and their exact source revisions are
recorded in [PR #355](https://github.com/larsbx/biz-kit/pull/355). This note defines
the acceptance contract; the existence of the test, script or workflow is not a
passing execution result. The earlier packaged results at
`8d36ed5373468106d48309470d669f8b4f370ed2` belong to #354 and do not accept later
source changes.

All scenarios use disposable local databases, identities and signing material.
The work does not merge the stack, deploy services, enroll real businesses or
couriers, or initiate live deliveries.

## Reused interfaces

The procurement source adapter already exists in the #353/#354 stack. The same
worker selects `:procurement` from configuration and uses the appropriate
signing domain, envelope type, role, business scope and endpoint. The integration
test exercises that path without creating a restaurant order.

| Boundary | Reused interface | Binding and authority |
|---|---|---|
| Coordinator queues fulfillment | `Procurement.request_dispatch/6`, reached through `ProcurementHost.Dispatch.request/3` | Existing chapter/cooperative/request, current operator grant, expected request version and separate pickup/drop-off code commitments. |
| Worker reads work | `Dispatch.RestaurantDelivery.work/2` → `POST /api/procurement-dispatch/work` | `ProcurementDeliveryWorkV1` signature, current enrolled route key, exact chapter/cooperative/tenant, timestamp window and one-use nonce. |
| Worker obtains authority | `Dispatch.RestaurantAutomation.poll/2` and its service-role resolution | Configured service role must be an organization-scoped `SERVICE` role with current authority; Board operations revalidate the actor for their own actions. |
| Worker creates/reuses a trip | `Dispatch.RestaurantAutomation.prepare/3` → `Dispatch.Operations.Board` | Exact procurement external reference, service tenant/carrier, fixed configured stops, configured courier and one planned assignment. Preparation runs in a database transaction with order and courier advisory locks. |
| Procurement accepts the handoff | `Dispatch.RestaurantDelivery.publish_automated/2` → `POST /api/procurement-dispatch` | Singleton `procurement_dispatch` signer over `ProcurementDispatchStepV1`, exact cooperative/order/tenant/load/assignment and stable command identity. The canonical Log admits the step. |
| Courier records custody | `Dispatch.RestaurantReceipts.submit/2` | Reauthorizes the participant, locks the assignment against concurrent change, requires self ownership and an active/completed assignment, resolves the procurement source and submits its signed code proof. |
| Worker finishes reconciliation | `Dispatch.RestaurantAutomation.poll/2` | Durable `accepted` work activates a planned assignment; durable `delivered` work completes the bound active assignment. |

The existing portal controller at `/ui/restaurant-receipts` delegates to this
receipt interface and supports procurement loads. Its historical path/module
names do not cause procurement orders to enter the restaurant business workflow.
The test drives the real portal router's login, role selection and receipt forms
through a Plug fixture with encrypted cookie sessions and valid CSRF tokens.
`PortalIdentity` issues synthetic identities and sessions through the existing
`BizKitSession` verifier; it does not replace that verifier with a stub. This exercises the
portal admission path without establishing external identity-provider or
graphical-browser acceptance. The worker's outbound procurement calls use a real
loopback HTTP server.

### Source configuration

The worker uses `PROCUREMENT_DISPATCH_*` settings: `AUTOMATED`, `CHAPTER`,
`COOPERATIVE`, `TENANT`, `KEY_ID`, `SEED_FILE`, `URL`, `SERVICE_ROLE`, `COURIER`,
`SITE`, `PICKUP` and `DROPOFF`. The configured host origin determines the two
procurement API URLs. The route enrolled in the business ledger must agree with
the chapter, cooperative, tenant, site and public signing key.

The test harness supplies synthetic settings only for its lifetime. Test setup
must preserve and restore the surrounding process configuration. The production
Dispatch dependency graph need not acquire a dependency on `procurement_host`
merely to compile the test: the integration harness explicitly supplies the
required host and ledger modules.

### Shared HTTP transport correction

The first executable worker run exposed a failure in the shared `Dispatch.Finch`
configuration before a work request reached the host. Its default TLS options
included `customize_hostname_check`. The locked Finch 0.24.0 removes the other
TLS-only options when opening an HTTP pool, but leaves this option in place;
Mint's TCP connection consequently exits with `:badarg`. This affects the
explicitly supported loopback HTTP integration, not a procurement business
transition.

The fix removes only that redundant override. It retains explicit
`verify: :verify_peer`, the CAStore trust bundle, verification depth and the
configured connection timeout. The locked Mint 1.11.0 installs its HTTPS
hostname matcher when peer verification is enabled. Regression tests exercise
the production Finch pool against loopback HTTP and an untrusted HTTPS
certificate. A third test copies the production TLS options into an isolated
pool, trusts only a disposable test CA, and requires rejection of a certificate
for the wrong hostname. No verification bypass or live endpoint is introduced.

### Exhausted work-feed cursor correction

Once HTTP requests could execute, the integration exposed a second adapter
defect. `ProcurementHost.Dispatch` used Erlang's `:json.encode/1`, which encodes
Elixir `nil` as the JSON string `"nil"`. An exhausted page therefore returned
`"next": "nil"` instead of `"next": null`. The worker retained that string as
its next cursor and could stop revisiting orders whose IDs sort before it.

The response now uses the host's existing Jason dependency, matching the
Dispatch work contract and preserving JSON null. The HTTP regression checks both
a short work page and an empty exhausted page. The actual-worker recovery test
requires the live worker to reset to the empty cursor and poll again without
another business-ledger append. This corrects polling/retry behavior without
changing order identity, quote acceptance or the custody reducer.

The existing procurement business reducer remains unchanged. Production changes
are confined to the shared transport options and the host's JSON response
encoder.

## Business and transport boundaries

### One request and one authoritative business ledger

The canonical `CoopSubstrate.Log` and its PostgreSQL EventStore remain the
authoritative business history. `ProcurementDispatchRequestedV1` attaches
transport commitments to an existing accepted request. It does not create a
second order. Dispatch uses the exact external reference
`procurement:<chapter>:<cooperative>:<request>` for its operational load, stops
and assignment.

Each admitted `ProcurementDispatchStepV1` is part of that same canonical history.
On delivery, `Procurement.apply_dispatch_fulfillment/3` applies the existing
`CommerceCore.MerchantPilot.Workflow` fulfillment transition to the original
request. Restart recovery reconstructs that request and transport state from
the canonical events. Dispatch's PostgreSQL assignment records serve the
transport lifecycle and do not become an independent procurement ledger.

### Original quote and payment evidence

Quote binding follows the original signed procurement acceptance and the
immutable `accepted_quote` on that exact request. The queue request records its
accepted version. The delivery step signs the order and transport identity;
it does not contain a new complete quote. The integration must assert equality
of the original accepted quote before and after fulfillment, including its
revision and commercial terms.

Pickup and drop-off use distinct order-bound commitments. A delivered receipt
becomes the request's fulfillment evidence reference `dispatch:<proof_id>`.
Delivery leaves the existing `payment_evidence` list unchanged. It is neither a
bank observation nor payment or settlement evidence. No price conversion,
clearing operation or new money movement is introduced by this adapter.

### Signers and code custody

The #353 correction remains in `ProcurementDispatch.step/3`: unsupported signer
counts return `procurement_dispatch_forbidden` before the singleton path can
match or crash. The singleton path still requires the current enrolled key,
public key and `procurement_dispatch` role. Rejection must preserve the Log
process, head, request and stored events, and a subsequent valid step must still
succeed.

The worker does not receive handoff codes from its work feed. The coordinator
page supplies them to the intended pickup/drop-off parties, and the authenticated
assigned courier submits them. The host checks the corresponding digest against
the already committed value. The configured coordinator secret must remain
stable while issued codes are outstanding; a change to that secret alters the
codes reconstructed by the page.

## Scenario contract

The following is the integration's acceptance contract. It is a list of required
observations, not a statement that an unexecuted test has passed. Consult the
revision-specific results before promoting a claim to verified.

| Scenario | Required observation |
|---|---|
| Authorized assignment | A current service role reads procurement-domain signed work, creates/reuses the exact load and configured stops, plans the configured courier, and activates only after canonical handoff acceptance. |
| Successful pickup/drop-off | The assigned current courier submits separate valid codes. The original request reaches fulfilled, the bound assignment reaches completed, the accepted quote is unchanged and payment evidence remains empty. |
| Busy courier | Another planned/active assignment leaves new work queued. No second trip is silently assigned; later reconciliation may proceed after the courier becomes available. |
| Rejected work authority | A wrong signing domain or replayed signed work request is refused. A fresh authorized poll can retrieve the same durable work. |
| Rejected receipt authority | A different courier submitting the bound assignment, or the original courier after role revocation, cannot advance the procurement handoff. |
| Rejected codes and ordering | A code from another order and premature drop-off leave the ledger and procurement row unchanged. |
| Signer-count rejection | A validly signed envelope with an extra signer is refused without terminating the appender or changing persistent state. |
| Retries | Repeated polling reuses the exact load/assignment. Freshly signed retries with the same accepted command/proof return the duplicate result without another ledger append. |
| Cancellation before acceptance | The procurement cancellation wins before custody; subsequent work reconciliation cancels any corresponding planned assignment and a late acceptance cannot revive the order. |
| Cancellation after acceptance | The canonical gate requires custody reconciliation and refuses an ordinary commercial cancellation. |
| Restart/recovery | Rebuilding the canonical Log preserves the original order and quote. A restarted worker recovers accepted, in-transit and delivered work using the same trip. The recovery fixture commits its Dispatch records and independently reads their identity/status from a separate PostgreSQL backend, so a shared uncommitted sandbox cannot supply the evidence. |

The dispatch client uses actual system time when signing. The existing general
procurement fixture uses a fixed test clock, so the integrated fixture must align
its clock, grants and session with the actual signatures. This is a test setup
requirement; production freshness checks remain in effect.

### Remaining courier scope

The pilot configures one site, one pickup/drop-off pair and one courier per
source. Availability checks consider `PLANNED` and `ACTIVE` assignments for the
configured operator participant in its configured Dispatch tenant. Restaurant
and procurement workers share that tenant/courier lock domain.

This scope does not establish exclusivity for the same physical person under
different participant IDs or across tenants. It also does not implement fleet
optimization, arbitrary route selection, reassignment during custody, return
logistics or automatic resolution of a postacceptance cancellation. Those remain
separate implementation obligations.

## Existing pure-module dependency

`CoopSubstrate.ProcurementDispatch` presently reuses `RestaurantCore.Delivery`.
Its `order_view` constructs a temporary input with `:ready`, `:dispatched` and
`:completed` stages so that the existing transport reducer can validate custody.
That reducer uses `Kitchen.legal?(:delivery, ...)`. Only the original procurement
row and transport fold are persisted; no restaurant order or kitchen record is
written.

This is a concrete pure-module dependency, even though the business ledger and
host interfaces are procurement-scoped. A neutral shared delivery reducer would
require a separate extraction with regression coverage for both consumers. This
integration verifies the existing adapter and keeps that dependency visible.

## Acceptance levels and reproduction

| Evidence level | What successful execution establishes | Limit |
|---|---|---|
| Pure/kernel and canonical ledger checks | Specified reducer, signed admission, replay and signer-count behavior in their stated model or runtime. | Formal models do not prove implementation refinement; ledger tests do not exercise Dispatch assignment. |
| Packaged procurement quickstart | The built procurement archive with bundled ERTS, HTTPS forms, PostgreSQL persistence and signed delivery endpoints under the packaged acceptance runner. | The courier is a synthetic signing client; `dispatch_handoff: true` alone does not prove the actual worker path. |
| Focused actual-worker source integration | Actual Dispatch polling, Board authorization/assignment and the portal session/receipt path interacting with the procurement HTTP host and PostgreSQL under the tested source revision. | Uses compiled source, a Plug portal fixture and test-issued identities/sessions with the real BizKitSession verifier; it does not establish a packaged Dispatch release, external identity-provider acceptance or a graphical courier browser. |
| Packaged Tauri procurement lifecycle | The separately tested Tauri/WebKit coordinator UI and packaged procurement host. | Its current delivery acceptance still uses the synthetic signing client. |
| Packaged Dispatch-to-procurement deployment | Requires separate acceptance of both deployed artifacts, their private configuration and the signed-in courier flow. | Pending; no live delivery or deployment is performed by this continuation. |

Run the focused integration using
[`scripts/test-procurement-dispatch.sh`](../../scripts/test-procurement-dispatch.sh)
or the dedicated
[`procurement-dispatch.yml`](../../.github/workflows/procurement-dispatch.yml)
workflow. The suite lives in
[`apps/dispatch/integration_test/procurement_delivery_test.exs`](../../apps/dispatch/integration_test/procurement_delivery_test.exs),
outside ordinary Dispatch test discovery. The harness stages its required
application closure without requiring the legacy restaurant host.

The fixture needs PostgreSQL with PostGIS, the canonical EventStore, Dispatch's
migrated schema and the locked Elixir dependencies. Use a disposable loopback
server: the harness resets `coop_substrate_eventstore_test` and migrates/tests
`dispatch_test`. Its explicit opt-in and synthetic database settings are:

```sh
export PROCUREMENT_DISPATCH_ACCEPTANCE=disposable-local-postgres
export EVENTSTORE_USERNAME=postgres EVENTSTORE_PASSWORD=postgres EVENTSTORE_HOST=127.0.0.1
export DATABASE_URL=ecto://dispatch:dispatch@127.0.0.1:5432/dispatch_test
bash scripts/test-procurement-dispatch.sh
```

Evidence is retained under `.artifacts/procurement-dispatch/<full-sha>/` with
`revision.txt` and the command logs. `result.json` is produced only after a
successful run. The existing
[`dispatch-partners.yml`](../../.github/workflows/dispatch-partners.yml) remains
the broader Dispatch regression and contract check.

Run [`scripts/procurement-quickstart.sh`](../../scripts/procurement-quickstart.sh)
for Docker-packaged procurement acceptance, or
[`scripts/test-procurement-host.sh`](../../scripts/test-procurement-host.sh) for its
host harness when the local toolchain is present. The
[quickstart guide](../../QUICKSTART_PROCUREMENT.md) explains the 13-check packaged
receipt, source revision and archive digest. Keep that receipt separate from the
worker integration result; do not relabel the existing `dispatch_handoff` check.

Record each run's exact source revision, tested command, terminal result and
retained log/receipt location. A passing dedicated run does not establish
repository-wide acceptance or attribute unrelated failures to this change.
The evidence remains an unsigned observation of the runner's execution. Missing,
skipped or pending execution must be reported explicitly.
