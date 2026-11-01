# biz-kit roadmap

## Priority: multi-organization tenant isolation — 2026-11-01

The [tenant-first architecture and acceptance contract](architecture/2026-11-01-multi-organization-tenancy.md)
and [tracking issue #233](https://github.com/larsbx/biz-kit/issues/233)
place organizational isolation ahead of optional provider and network expansion.
**WorkOS feature expansion and NetBird integration are deferred**; do not
remove the existing WorkOS sign-in adapter. WorkOS organization/permission
records are not a business-authority source, and NetBird connectivity would
not enforce tenant isolation.

The [partial T0 source review](architecture/2026-11-01-multi-organization-t0-source-audit.md)
identifies unscoped legacy Eatsbot/SpruceGoose models as shared-tenant rollout
blockers. The standalone tenancy inventory workflow emits an exact-source
review queue, not authorization proof. The first Dispatch implementation also
refreshes user/participant/organization status before held-actor operations
and locks actor role, participant, user, organization and role definition
inside administrative mutations. Two-connection revocation/suspension tests
are added, but hosted acceptance is still unverified.

The stages are: **T0** ownership and unsafe-query inventory; **T1** verified,
non-unioning acting context on web/native/stream/job/extension paths; **T2**
Ash, raw SQL, PostgreSQL and hosted integration isolation; **T3** explicit
partner sharing and domain-owner admission; **T4** signed portability to an
independently governed home, with single-writer fencing. The first Dispatch
slice adds organization-qualified role labels and checks organization
lifecycle during role selection/revalidation. It does not establish T2/RLS,
production cutover or cross-home federation.

## Proposed Halaqa federation over Iroh — 2026-10-31

The [native federation boundary](architecture/2026-10-31-halaqa-iroh-federation-boundary.md)
records F0–F5: pinned offline format conformance; Halaqa owner decisions;
independent signed Rust/Elixir verification; native Iroh delivery with
application HTTP disabled; real domain admission; optional ActivityPub HTTP
compatibility. F0 is a test-only snapshot/oracle, not an activated protocol,
verified authority adapter or production cutover. Halaqa owns the proposed
semantic contract in [PR #9](https://github.com/larsbx/halaqa/pull/9).

The pinned follow-up also exercises exact-byte Ed25519 signatures, explicit
local TEST actor/key/context bindings and lifetime/revocation refusal across
48 signed vectors. This prepares F1 review; it does not close identity
succession, production authorization, durable replay or independent Rust/Elixir
verification.

## Existing consolidation roadmap

Updated 2026-10-22 (security audit priorities and Slice 1 status). The direction is
[one source of truth](architecture/2026-10-11-single-source-of-truth.md):
one signed business-event ledger, one command admission path, one principal
registry and one PostgreSQL database. Task, dispatch, ownership and economic
views become rebuildable projections. The task and workflow rules are a
dependency-free core that other applications vendor
([task core](architecture/2026-10-20-task-core.md)).

The consolidation order (step 1 is done) is:
1. retire the notes spike;
2. take one task transition end to end;
3. move the whole orchestration write surface;
4. move dispatch and ownership;
5. finish cutover and delete the old writers.

The project is in step 3, within an isolated instance. The production writer
has not been switched.

## Delivered

**The common ledger's task lifecycle**
- [First task command](architecture/2026-10-11-first-ledger-task-command.md),
  [Definition of Done, evidence and review](architecture/2026-10-11-dod-evidence-review.md),
  [artifact custody](architecture/2026-10-12-artifact-custody.md),
  [queued and ready](architecture/2026-10-14-ledger-task-readiness.md).
- [Execution: start, evidence, review, complete](architecture/2026-10-19-execution.md),
  [cancel and reopen](architecture/2026-10-19-cancel-reopen.md).
- [Timing and agent suggestions](architecture/2026-10-18-task-timing-and-suggestions.md),
  [delegated changes](architecture/2026-10-18-task-delegation.md).

**People, devices and administration**
- [Identity](architecture/2026-10-18-identity.md),
  [device enrolment](architecture/2026-10-19-device-enrolment.md),
  [device revocation](architecture/2026-10-19-device-revocation.md),
  [revoking one's own devices](architecture/2026-10-19-own-devices.md).
- [Administration in the view](architecture/2026-10-19-administration.md),
  [every project of a chapter](architecture/2026-10-19-chapter-projects.md),
  [offboarding](architecture/2026-10-19-offboarding.md),
  [offboarding from a chapter](architecture/2026-10-19-chapter-offboarding.md).

**The web view**
- [Change feed](architecture/2026-10-18-change-feed.md),
  [deciding on suggestions](architecture/2026-10-18-decide.md),
  [editing before accepting](architecture/2026-10-19-amend.md),
  [lifecycle steps](architecture/2026-10-19-lifecycle.md),
  [uploads](architecture/2026-10-19-uploads.md),
  [the view follows the ledger](architecture/2026-10-19-live-view.md).

**Operations**
- [Cluster](architecture/2026-10-19-cluster.md),
  [rate limits](architecture/2026-10-19-rate-limits.md),
  [durable evidence quota](architecture/2026-10-20-durable-quota.md).

**Task and workflow core**
- [Task core](architecture/2026-10-20-task-core.md): the rules as a vendorable
  app behind host ports, sharing one lifecycle contract and DAG with
  SpruceGoose.
- [Hierarchy and blueprints](architecture/2026-10-20-hierarchy-and-blueprints.md):
  roadmaps and workflows as a reviewed, source-pinned document. A workflow
  run creates its tasks with their Definitions of Done and predecessors.
- [Workflows in the view](architecture/2026-10-20-workflow-view.md): list a
  project's workflows and run one from the page.
- [Readiness for a workflow run](architecture/2026-10-20-run-readiness.md):
  governance defines a run's readiness in one signed batch. With this, a run
  can go from blueprint to completion outside the tests.
- [What the ledger keeps from SpruceGoose](architecture/2026-10-20-sprucegoose-salvage.md):
  todos that gate completion, no predecessor cycle across a project, and
  SOP versions that never go back.

**Dispatch**
- [Capability document](architecture/2026-10-20-dispatch-capability-document.md):
  `GET /v1/role-capabilities` signs what dispatch offers a role assignment
  with the ledger's scheme (Ed25519 over canonical bytes); the d-patch field
  app verifies it against a pinned key and gates its status screen on it.
  `GET /v1/me/role-assignments` lists the assignments a principal may select.
- [Native sign-in](architecture/2026-10-21-native-sign-in.md): an app signs in
  through the system browser (RFC 8252, PKCE) and gets a biz-kit session as a
  bearer token; dispatch's `/v1` accepts it (`BizKitSession` verifier).
- [Device keys](architecture/2026-10-21-device-keys.md): `POST /v1/me/devices`
  registers an installation's Ed25519 key by proof of possession; a status
  declaration naming the device must carry its signature and is stored
  `DEVICE_AUTHENTICATED`.
- [Role administration](architecture/2026-10-22-role-administration.md):
  Courier capabilities and the administrator grant/revoke surface are merged
  ([biz-kit #61](https://github.com/larsbx/biz-kit/pull/61),
  [d-patch #18](https://github.com/larsbx/d-patch/pull/18)). Scenario 15 has
  end-to-end coverage; the audit obligations below still apply.

## Security and validation gate (2026-10-22 audit)

These source-review findings were checked at main
[`40cb89a`](https://github.com/larsbx/biz-kit/commit/40cb89ad0020b040f2fbaffe3812e5d154b98319).
They are open obligations, not implemented fixes or demonstrated production
incidents. Resolve them before extending affected session or administrative
authority or claiming production cutover readiness.

| Priority | Obligation | Required evidence for closure |
| --- | --- | --- |
| P1 | Make native-session restoration atomic with logout and principal revocation. `Sessions.fetch/2` reads the persistent store outside the singleton, while revocation clears memory and storage separately; an overlapping restore can repopulate a revoked session. | Deterministically pause a store read/restore, revoke the token or principal, then resume it. The token must remain refused after both operations finish, after restart, and on another node. Preserve durable sessions that have not been revoked. |
| P1 | Bind Dispatch portal authentication to revocable server-side session state. The token exchange keeps a subject and authentication time; subsequent portal requests resolve assignments without checking the originating Identity session. | With assignments unchanged, prove that logout, principal-session revocation, identity unbinding, and source-session expiry refuse subsequent protected portal requests. Apply the same authentication rule to streams and reconnects. Keep bearer tokens out of cookies and logs. |
| P1 | Revalidate administrative authority inside the mutation transaction after acquiring its organization lock. `Administration` currently checks the actor's preloaded assignment, which can have been revoked while the request waited. | With separate database sessions, resolve an actor, block its mutation, revoke its authority, then release it. No grant, revocation, or audit record may commit under the stale authority. Cover participant/user suspension and role-definition changes with the appropriate shared locks or serialization. |
| P2 | Require PostgreSQL/PostGIS-backed Dispatch integration checks in hosted CI. The current Consolidation job runs its unit tier and excludes integration-tagged authorization tests. | A required job creates and migrates the PostGIS database and runs `mix test --include integration`, including administrative and portal regressions. Record the exact tested PR head; a green unit-only run does not close this obligation. |

Native-session correction: the focused implementation and validation are described
in [atomic native-session revocation](architecture/2026-10-22-atomic-native-session-revocation.md).
Its local deterministic races reproduce the original defect and pass with the
correction, including PostgreSQL and singleton migration checks. This is PR
implementation evidence; the gate still requires review and hosted validation.
The portal-authentication, administrative-transaction and required Dispatch CI
obligations above remain open and are not resolved by this correction.

Implementation anchors:
[`Sessions`](../apps/biz_kit_identity/lib/biz_kit/identity/sessions.ex),
[`SessionController`](../apps/dispatch/lib/dispatch_web/controllers/session_controller.ex),
[`PortalSession`](../apps/dispatch/lib/dispatch_web/plugs/portal_session.ex),
[`Administration`](../apps/dispatch/lib/dispatch/accounts/administration.ex), and
[Consolidation](../.github/workflows/consolidation.yml).

The original task singleton-signer rejection remains implemented in
[`TaskCore.Admission`](../apps/task_core/lib/task_core/admission.ex); preserve it,
the existing cooperative-event signature semantics, and canonical encoding.

Audit baseline: [main CI run 39753381007](https://github.com/larsbx/biz-kit/actions/runs/39753381007)
passed ledger/orchestration, release smoke, and model checks at `a85aea3`.
Its Dispatch tier reported 217 excluded tests. The audit also ran 25 browser
module tests successfully; it did not run local Elixir/PostgreSQL reproductions
of the findings. CI success is evidence for the checks actually run, not for
absence of these races.

## Next

1. **Close the security and validation gate above.** Land focused corrections
   with the specified regressions and fresh validation before expanding the
   affected authority surfaces.
2. **Finish Slice 1 partner actions.** Review and validate
   [biz-kit PR #62](https://github.com/larsbx/biz-kit/pull/62) with its paired
   [d-patch PR #19](https://github.com/larsbx/d-patch/pull/19). Scenarios 17–19
   remain pending integration; do not count an open PR as delivered.

## Next: workflow usability

After the security gate, retain the existing workflow usability work:

1. **Workflows for administrators.** The chapter's feed and its projects card
   carry each project's workflows and runs, so an administrator sees which
   runs wait on them without opening each project.
2. **Readiness from the command line.** Add `mix coop.readiness`, the run
   readiness batch for a script holding the governance key, as
   `coop.offboard` is for offboarding.
3. **Per-step SOPs.** Let a run's readiness use a different SOP for different
   steps (several batches, or one SOP per step in the dialog). The ledger
   already allows it.
4. **Retiring a workflow.** Decide what a revision that omits a workflow
   means: it stays, it is retired, or it is refused. Then model it.
5. **Applying a blueprint from the page.** An administrator gives the forge
   source and the page verifies it. Today this is done only by
   `mix coop.blueprint`.

## Dispatch field app (d-patch)

Dispatch's server work happens here; d-patch keeps the Android, web and e2e
clients (d-patch ADR-0010). The Android app's offline status flow is built,
the app signs in through biz-kit's [native sign-in](architecture/2026-10-21-native-sign-in.md)
(d-patch `core:auth`, ADR-0011), and biz-kit checks [device keys](architecture/2026-10-21-device-keys.md).
The native-session and device-signing client integration is merged
([d-patch #17](https://github.com/larsbx/d-patch/pull/17)); it is no longer
a missing implementation step. Deployment still exposes SpruceGoose's `/auth`,
sets `BIZKIT_NATIVE_REDIRECT_URIS`, and selects Dispatch's `BizKitSession`
verifier.

The native session/device-key and courier/role-administration work is followed
by [partner actions](architecture/2026-10-22-partner-actions.md): stop readiness,
nonbinding proposals, encrypted proof references, and a relationship-scoped
broker load and own-thread-metadata view. d-patch's real-server suite exercises
17–19 with JavaScript enabled and disabled, including a stale offline form.
The paired PRs preserve #61/#18 behavior and use separate acceptance branches.

What remains, in order:

1. **Security and required CI.** Close the session, administrative-admission,
   and integration-gate obligations above.
2. **Hosted partner acceptance and later slices.** Run the new PostGIS partner
   gate and paired browser suite; retain Android driver/courier emulator jobs.
   Record browser, emulator and handset evidence separately. Consented
   location/status/ETA summaries (Slice 2), provider message content/intake
   (Slice 4), and common approval/execution controls (Slice 5) remain open.
3. **Grants instead of the document.** When Dispatch's roles become ledger
   grants (consolidation step 4), the app reads them from the change feed and
   the capability document retires.

## Later: consolidation steps 3–5

- **Orchestration write surface.** Move SpruceGoose's remaining writes onto
  the ledger with dual-read parity, then fence the old writer:
  - its Ash hierarchy and schema-1 blueprints.

  Its todos, predecessor-cycle refusal and SOP versions are on the ledger
  ([what the ledger keeps from SpruceGoose](architecture/2026-10-20-sprucegoose-salvage.md)).
  Its deployment domain, derivation permits, release provenance, runtime
  shadows, boards and inbox captures are not migrated; they go with its
  writer.
- **Dispatch and ownership.** Move dispatch, Keel ownership and shared
  principal facts onto the same admission path.
- **Cutover.** Fence the old writers behind a signed baseline and prove
  replay. Then retire the old row authority, the local certified writer,
  the business outboxes and the duplicate issuers.

## Open questions

- **Single-project offboarding.** Should it, like chapter offboarding,
  cancel the person's pending requests only once the offboarding is
  admitted?

Portal correction in progress: see [revocation-aware portal authentication](architecture/2026-10-23-revocation-aware-portal.md). This implementation is not yet acceptance evidence and does not close the administrative P1 or required hosted-integration P2.

## Modular business platform (2026-10-24)

[Architecture decision](architecture/2026-10-24-modular-business-platform.md):
keep Eatsbot, d-patch and SchoolOps independently evolvable. Extract reusable
capabilities from real domain implementations into narrowly scoped biz-kit
modules and contract/SDK surfaces; do not freeze domain product development.
This is additive to the existing signed-ledger consolidation and **does not
satisfy** any pre-existing security or writer cutover gate above.

1. **Commerce arithmetic — first slice:** extract Eatsbot I₂ line and total
   pricing to `commerce_core`; keep `EatsbotCore.Orders.Pricing.price/3` as
   a compatibility facade; prove exact parity in tests. No database changes.
2. **Catalog/price model:** inventory Eatsbot Product, Variant, Price, option
   and discount constraints, resolve tenant/merchant boundaries and public
   API ownership, and identify contract-compatible extractions. Do not
   automatically move its Ash resources or tables.
3. **Inventory:** design a dedicated stock ledger (locations, adjustments,
   reservations, committed movements, reconciliation). There is no delivered
   generic inventory subsystem in Eatsbot to move wholesale. Protect stock
   against concurrent reservations and avoid representing sale orders as
   stock movements.
4. **Commerce order vs restaurant order:** isolate generic line snapshots,
   idempotency, pricing, order commitments, refunds/returns, and commercial
   state from Eatsbot's kitchen and dine-in lifecycle. Preserve current order
   IDs, checkout concurrency and transaction semantics through parity tests.
5. **Dispatch contract:** define order fulfillment requests/results across
   domains. Eatsbot retains commercial order state; Dispatch owns routing,
   assignment, driver/device declarations and transportation state. Do not
   blindly fuse their present delivery state machines or databases.
6. **Cross-domain sales/marketing:** design contact/party relationships,
   consent, account scopes, leads, opportunities, campaigns and event
   provenance. Do not infer promotional consent from customer accounts.
7. **Later HR and financial operations:** adopt reviewed domain models
   for employment and accounting; do not mistake the existing signed
   business-event ledger for double-entry accounting.

Each follow-on slice requires one consuming domain, one non-Eatsbot
portability/conformance test, explicit authority, and a proved source/target
contract. Independent deployments may consume version-pinned code or
authenticated APIs; a single logical fact has one active writer.

## Delivered rule kernels and remaining production gates (2026-10-24)

| Scope | First slice merged | Remaining obligation |
| --- | --- | --- |
| Merchant catalog | [PR #85](https://github.com/larsbx/biz-kit/pull/85): pure product/variant/price rules and read-only Eatsbot adapter | #81: merchant-authorized persistent API, discount precedence, tenant price revisions, schema/event parity |
| Inventory | [PR #86](https://github.com/larsbx/biz-kit/pull/86): exact units, holds, movements, idempotency, replay | #82: ledger admission, real concurrency/custody, durable expiry/reconciliation, consumer integration |
| Fulfillment | [PR #87](https://github.com/larsbx/biz-kit/pull/87): request/ack/proof/cancel protocol, domain adapters | #83: authenticated Dispatch transport admission, outbox/inbox retry, cancellation race and legacy parity |
| Sales/marketing | [PR #88](https://github.com/larsbx/biz-kit/pull/88): lead/quote state, evidence-based consent, suppression and candidate campaigns | #84: encrypted contacts, authenticated consent, privacy/regulatory policy, cross-channel suppression and delivery |

All four are **code merged**, not a claim that their associated production
milestones are complete. The original issues remain open for their explicit
end-to-end obligations; new usage must not bypass identity, signed admission,
or existing payment/transport authority. HR and actual financial accounting
remain future capabilities.
