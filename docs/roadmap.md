# biz-kit roadmap

Updated 2026-10-21 (dispatch native sign-in and device keys). The direction is
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

## Next

Ordered by what blocks real use first.

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
What remains, in order:

1. **The app's half of device keys** (in d-patch): make and seal the key,
   register it after sign-in, and sign each declaration when it is queued.
   Deployment exposes SpruceGoose's `/auth` publicly, sets
   `BIZKIT_NATIVE_REDIRECT_URIS` and selects dispatch's `BizKitSession` verifier.
2. **End-to-end runs.** d-patch's Slice 1 exit tests (1, 13–19, online and
   after an offline interval) against this server rather than d-patch's frozen
   `central/`.
3. **Grants instead of the document.** When dispatch's roles become ledger
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
