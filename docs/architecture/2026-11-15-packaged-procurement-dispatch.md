# Packaged procurement with the actual Dispatch process

## Purpose and evidence boundary

PR #355 established the source integration between ProcurementHost and the
Dispatch worker, assignment Board and authenticated courier receipt route. Its
final packaged procurement quick-start and host/Tauri checks also passed, but
their delivery client fabricated its load/assignment identifiers and signed the
endpoint requests directly. Passing those two suites separately did not execute
the actual worker against the packaged host.

This continuation joins those components in one bounded acceptance gate:

- Procurement runs from its exact-revision archive using the bundled ERTS.
- Dispatch runs from the staged source at the same revision, in a separate VM
  for every peer invocation.
- Dispatch's committed PostgreSQL records supply the actual tenant, courier,
  load and assignment identities.
- The original procurement order and its delivery evidence remain in the
  packaged host's one canonical business ledger.

The gate uses disposable identities, keys, locations and databases. It does not
deploy, merge, start a live delivery or establish external payment evidence.
The existence of the harness is not a passing execution result: consult the
exact-head workflow and retained receipts.

The process boundary exposed a missing adapter initialization: procurement's
delivery envelope is an extension schema registered by ProcurementHost. The
earlier source suite started that host in Dispatch's VM, while an independent
Dispatch VM had no such registration. The procurement signing branch now calls
the existing Procurement.register_types!/0 before constructing its envelope.
This registers pure schema data and starts neither the host nor the ledger. The
peer requires that schema to be absent at fresh startup, so the combined gate
exercises the adapter's own registration instead of inheriting it from setup.

## Interfaces and transports

The adapter uses the existing procurement variant of the interfaces introduced
for restaurant delivery. It creates no restaurant order and calls no kitchen
or restaurant host endpoint.

| Step | Actual interface | Observation |
|---|---|---|
| Queue | Coordinator form in the packaged ProcurementHost | The existing accepted order supplies the handoff request. |
| Read work | RestaurantAutomation GenServer and RestaurantDelivery.work/2 | The real worker signs procurement-domain work requests. |
| Assign | Current organization-scoped SERVICE role and Operations.Board | The configured courier receives a real PostgreSQL load and assignment for the exact procurement reference. |
| Record pickup/drop-off | BizKitSession verifier, portal login and role selection, DispatchWeb.Router and RestaurantReceipts.submit/2 | The assigned courier presents the separately committed codes through the authenticated receipt route. |
| Fulfill | Signed ProcurementDispatchStepV1 admitted by the packaged host | The original accepted order becomes fulfilled, with dispatch:<proof_id> as its outcome evidence. |
| Reconcile | A fresh RestaurantAutomation process over committed SQL | The same assignment activates/completes; retries do not create another trip or business event. |

The coordinator uses the existing verified loopback HTTPS proxy and Secure
cookies. Worker-to-procurement requests use the production client's explicitly
supported private loopback HTTP origin. The courier exchange drives the actual
Router through Plug, with encrypted cookie sessions and CSRF; it is not a
graphical browser or an external identity-provider test. The receipt states
these three transport boundaries explicitly. Production TLS trust is unchanged.

The current pure-module dependency on RestaurantCore.Delivery and its
Kitchen.legal?/3 checks remains. That dependency does not create restaurant
business records. Extracting a neutral delivery reducer requires separate
regressions for both consumers; replacing it with the incompatible API from
PR #365 is not part of this continuation.

## Combined lifecycle

The Python runner reuses the existing packaged lifecycle and its 13 host
checks. The legacy default still uses the synthetic courier and writes the
legacy receipt kind. The combined runner injects a distinct delivery driver:

1. Start only Dispatch in a source VM after validating the test mode, explicit
   opt-in, loopback database, private files and fixed origin. Create a carrier,
   courier DRIVER role and organization-scoped SERVICE DISPATCHER role in one
   committed transaction. Record their actual IDs in a private checkpoint.
2. Enroll that real fixture tenant and route key in the offline canonical
   bootstrap before starting the packaged host. The host receives neither the
   fixture governance key nor the Dispatch signing seed.
3. Create and qualify one business request, quote two revisions, reject the
   obsolete quote, and accept revision 2. Stop the host and inspect the complete
   accepted quote; compare all seven fields with the original coordinator form
   inputs, including supplier, currency, expiry and source reference.
4. Restart the host, queue delivery, and run the actual worker. Require one load
   and one active assignment with the exact external reference
   procurement:<chapter>:<cooperative>:<order>. A fresh worker VM must reuse them.
5. Reject the drop-off code at pickup, then accept the correct pickup through
   the assigned courier's authenticated portal route. Stop the host and inspect
   the two actual signed custody steps.
6. Restart the packaged host and run another fresh Dispatch VM. Compare the
   complete canonical snapshot and the committed assignment. In-transit custody
   must survive without another append or replacement assignment.
7. Reject the pickup code at drop-off, accept the correct drop-off, and run a
   fresh worker to complete the same assignment. Repeat delivery and polling;
   the authoritative history must remain exactly equal.
8. Retry the original coordinator command, restart the host, revoke the
   coordinator grant, back up and restore PostgreSQL, and check revoked access.
   Verify full quote and custody bindings after restoration as well as the
   existing head/hash and revocation checks.

The final offline inspection requires exactly three signed Dispatch steps,
accept/picked_up/delivered, with transport versions 0/1/2. Every step must have
the original order/chapter/cooperative, actual tenant/load/assignment, one
declared route signer and one signature. The pickup/drop-off proof digests must
match the presented codes. The final outcome must refer to the authoritative
delivered proof ID. The prequeue ledger has 10 events, delivery adds four, and
coordinator revocation adds one: 15 events after restoration. No restaurant,
payment or settlement event is permitted.

The seven existing focused source scenarios continue to cover revoked service
and courier authority, another courier, busy couriers, wrong-order codes,
premature drop-off, replay, multi-signer rejection, preacceptance cancellation,
custody cancellation fences, and the accepted-before-activation recovery
boundary. Those scenarios are not relabeled as separate-process packaged
execution.

## Process and database ownership

The peer runs with mix run --no-start --no-compile. Its guards precede
Application.ensure_all_started(:dispatch). Both before and after each action it
checks that neither coop_substrate nor procurement_host nor a canonical Log
registration is running in that VM. Dispatch's existing runtime:false substrate
dependency supplies signing code without starting the ledger.

The parent constructs a separate environment for the peer. It does not forward
the host's operator/governance seeds, login/session configuration, EventStore
variables or unrelated integration credentials. The peer receives the disposable
Dispatch database and its route seed file. The test database role is privileged
for schema setup; this gate demonstrates appender ownership and separate
operational state, not PostgreSQL privilege isolation for production roles.

Canonical inspection and bootstrap use the bundled executable only while the
host process is stopped. The ordinary inspection result remains compatible with
existing packaged receipts. The added inspect_dispatch mode checks signatures
and both hash chains, then returns complete quote and custody binding evidence.

Each source invocation uses an unsandboxed committed PostgreSQL connection.
Fresh VMs cannot obtain previous uncommitted sandbox state. Private fixture
metadata pins the origin, scope, seed fingerprint and database. Bootstrap flushes
the complete identity checkpoint before committing its transaction; cleanup
validates ownership and deletes only the created tenant and user. Handoff codes
and private seeds remain in the temporary work directory, not receipt artifacts.

## Reproduce and inspect

Run scripts/test-procurement-dispatch.sh from a clean checkout with the existing
documented disposable PostgreSQL/PostGIS settings. It stages the application
closure, runs the canonical signer checks, all Dispatch tests, the seven focused
scenarios and machine contracts, then builds the procurement archive and runs the
combined driver. PostgreSQL 16 client tools and OpenSSL are required in addition
to the locked Elixir/OTP/Rust toolchain. The dedicated GitHub workflow installs
these clients and uses the same script.

The artifact directory .artifacts/procurement-dispatch/<full-sha>/ contains:

| File | Evidence |
|---|---|
| result.json | Existing source-worker PostgreSQL result and source-stage log digests. |
| procurement-release.tar.gz and artifact.sha256 | The bundled procurement artifact and its hash. Its SOURCE_REVISION must match the staged Dispatch marker and receipt revision. |
| packaged/receipt.json | Distinct procurement-packaged-dispatch-acceptance-v1 result, 13 host checks and 14 Dispatch checks, actual assignment, full accepted quote, signed custody metadata and log digests. |
| Source and packaged logs | Test counts, contracts, build output, bounded peer observations and offline ledger inspections. |

The combined receipt has execution_kind
packaged-procurement-source-dispatch-postgresql, trust
unsigned-runner-observation, packaged_dispatch_worker:false and
live_delivery:false. Its source revision and archive hash are mandatory.
A stale success is removed before preflight; a receipt is written only after
all checks and fixture cleanup succeed. Runner controls reject changed bindings,
quotes, extra signers/signatures, missing or truthy non-boolean checks, unsafe
database settings and inappropriate packaging/transport claims.

A passing combined receipt establishes packaged procurement communicating with
the actual source Dispatch worker and authenticated courier route. It still
leaves a separately packaged Dispatch release, target-host private configuration,
worker-to-host HTTPS with deployed trust, external IdP authentication, graphical
courier acceptance and live delivery outside the verified boundary.
