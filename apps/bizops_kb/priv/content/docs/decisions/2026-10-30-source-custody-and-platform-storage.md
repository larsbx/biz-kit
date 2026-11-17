# Knowledge source custody and disposable retrieval indexes

Original decision: 2026-10-30 (America/Chicago).

Revision: 2026-11-14 (America/New_York), for SpruceGoose's migration.

Status: **Selected integration target. Knowledge-specific adapters and live
authority cutover are not established by this decision.**

## What this revision changes

The [original decision][original] and README named SpruceGoose and the
Systemwide SOP as the operational admission, promotion and distribution
authority. SpruceGoose is being retired, with retained capabilities moving to
Biz-kit. This revision replaces that permanent runtime dependency with named
successor responsibilities and a cutover contract for each affected workflow.
Applicable SOPs remain versioned policy inputs; their admission does not depend
on retaining SpruceGoose's host, local issuer or legacy command names.

Source custody, provenance, scoped access, withdrawal, historical receipt IDs
and one active business writer remain requirements. Existing live workflows
retain their evidenced owner until a verified handover. A new read-only import
can proceed independently of SpruceGoose's full decommission; it grants no
operational publication or execution authority.

## Evidence and ownership

This mapping uses Biz-kit main
`6414c58f50212e2cd47ed732400f859472b49d89` and SpruceGoose main
`beb513dc8186d4c246383cf7d9c381eea6c849ad`. It records source-level ownership,
not a claim that the knowledge integration or production cutover has run.

| Concern | Owner or integration target | Implemented boundary and remaining work |
| --- | --- | --- |
| Editable knowledge, attribution, Johnny.Decimal paths and stable references | `bizops-kb` Git source, with explicit ownership for any later corpus move | Copies into Biz-kit are permitted; a copy or index does not change authorship or source ownership. |
| Authentication and principal/session binding | `BizKit.Identity` | The native session store moved out of SpruceGoose. A login alone does not grant document access, publication or task authority. |
| Operator interface and source-verification entry point | `task_host`, including `TaskHost.Blueprints.SourceVerifier` | Task surfaces and the Forgejo blueprint verifier moved in [#356][rehost-pr]. This is not yet a general GitHub knowledge importer or publication endpoint. |
| Retained task rules and SOP readiness | `TaskCore` with `CoopSubstrate` admission | Existing task rules and SOP version/digest checks are retained. Knowledge review, promotion and withdrawal semantics still need an explicit mapping. |
| Accepted operational knowledge decisions | The existing signed `CoopSubstrate.Log` admission path | Define and verify knowledge-specific commands, versioned event types and replay before enabling mutations. Do not create an independent knowledge business ledger. |
| Referenced evidence bytes and custody receipts | `CoopSubstrate.ArtifactCustody`, backed by persistent `COOP_ARTIFACT_DIR` | Existing scoped receipt admission verifies bytes. Receipt existence, current availability, review acceptance and publication permission are separate predicates. |
| Retrieval views and delivery scheduling | PostgreSQL projections and the selected shared Redis contract | Knowledge indexing/delivery adapters remain proposed. Redis stores rebuildable operational data and confers no approval or durable business authority. |

The [TaskHost decision][task-host] records that SpruceGoose's web/API surface,
authentication endpoint, blueprint source verifier and `mix coop.blueprint`
were rehosted. SpruceGoose's imported legacy writer and CLI remain; it binds
no HTTP port. The owner dropped `/mcp` and its local OAuth2 issuer. A future
agent interface must use current task commands and authentication, rather than
depend on those retired endpoints.

The existing [source-verifier interface][source-verifier] returns verified
tree, digest and bytes for a repository/commit/path through a configured
adapter, currently defaulting to Forgejo. A GitHub-backed `bizops-kb` importer
must verify provider/source compatibility and exact Git object and byte identity,
using access credentials where required. The interface name alone is not
evidence that this importer exists.

The [salvage decision][salvage] excludes legacy deployment, derivation,
runtime-shadow, board and inbox features from Biz-kit's migration. Knowledge
integration does not require reconstructing those features or importing their
old authority. Preserve relevant historical evidence and explicitly map or
retire each real consumer. AgentCore, if used for later effects, requires its
own admitted task and execution adapter; it is not a prerequisite for reading
the vault.

## Source, admission and retrieval contract

### 1. Preserve source identity when copying or moving content

Git retains editable source bytes, attribution, rights, original paths and
exact revisions. Preserve Johnny.Decimal structure and stable references.
Pinned, attributed imports into Biz-kit are allowed. Each import manifest must
identify the source repository, full commit and tree, original path, content
digest, document/Johnny.Decimal identity, transformation version if any, and
destination installation and visibility scope. Preserve the original bytes
or a retrievable verified source alongside a transformed representation.

While this repository owns a corpus, copied content is an imported view. If
editing moves to Biz-kit, record the corpus boundary, new source owner, pinned
baseline and ID/path mapping, then end the previous authoritative write path.
Avoid two independently editable authorities for the same corpus. A later
source revision must be selected explicitly; imports never silently follow
`main` or substitute the latest document for an admitted version.

### 2. Admit operational decisions through the common signed history

A source commit, successful import, embedding or custody receipt does not
approve an SOP or publication. Knowledge-specific admission must bind the
exact source manifest, current principal and scoped grant, intended audience,
installation, applicable SOP/policy version, review decision and expected
aggregate version. Define the admitted result and stable event identity before
implementing promotion, withdrawal or distribution commands.

Use the existing serialized append boundary to recheck current authority,
source revision, prior admission and withdrawal state. Failed append changes
no business state. Acknowledge only durable admission; projections follow
accepted history. Replay reconstructs publication status and access decisions
without distributing documents or executing procedures.

PostgreSQL may retain approved manifests, provenance, review/admission evidence,
delivery records and query projections under the [shared storage contract][storage].
These records must have explicit ownership; projection rows cannot license a
new business mutation. Retain original receipt IDs and source mappings during
migration. A signed migration baseline records its own observation, not a
new signature or approval on behalf of an old participant.

### 3. Keep custody and access distinct

Use the existing [scoped artifact custody contract][custody] when a command
requires receipt-backed evidence. Its internal `ArtifactCustody.get/3` expects
an independently authorized reader; it is not a public access-control API.
The knowledge-facing adapter must check current reader scope and withdrawal
before returning a restricted body or snippet, and must recheck authority at
any later effect boundary.

`COOP_ARTIFACT_DIR` is the common-ledger artifact location.
`ARTIFACT_STORE_ROOT` names SpruceGoose's legacy store. Inventory both before
moving referenced material; verify every retained receipt against its bytes
at the destination. Moving configuration or copying a directory does not
establish this gate. A missing or corrupted body makes availability false
while its historical receipt remains intact.

### 4. Make retrieval and delivery rebuildable

Redis may hold scoped search indexes, metadata caches and indexing delivery.
Key derived state by source revision, visibility and installation scope.
Rebuild from retained source plus admitted publication records. Cache loss
cannot promote a draft, erase a withdrawal or restore revoked permission.
Check current access and withdrawal when serving results; a stale cache hit
cannot authorize a later action.

Keep restricted SOP/artifact bodies and credentials out of public caches,
public snippets and stream payloads. Delivery jobs carry bounded references
and stable effect IDs backed by durable intents and outcomes. Duplicate work,
lost responses, Redis loss and restart must reconcile the same admitted
operation rather than repeat promotion or distribution. A lease or TTL is
not the permanent idempotency record. Remove covered Oban/legacy delivery
only after replacement recovery and backlog reconciliation pass.

Retrieval, publication to an audience and execution of a procedure remain
separate authorizations. An indexed financial procedure grants no payment
authority. The [Hawala boundary][hawala] remains separate; TigerBeetle is not
a document store or knowledge authority.

## Migration and acceptance

Apply cutover per retained capability and corpus. Inventory the actual source,
consumer, current owner, receipt IDs, open work and destination. Old task IDs,
host paths, environment variable names and historical acceptance are evidence
to reconcile; they do not establish current service permissions.

| Gate | Required reproducible evidence |
| --- | --- |
| Pinned import | A selected repository/commit/tree/path reproduces the recorded digest, IDs and references. Changed bytes, wrong revision, missing source and an unapproved revision are refused for operational use. An import remains unadmitted until its separate review/admission passes. |
| Scoped admission | Unauthorized or revoked principal, wrong audience/installation, stale version, withdrawn document and failed append leave business state unchanged. Custody alone cannot approve publication. |
| Access and withdrawal | Restricted bodies/snippets remain inaccessible across scopes. Warm and rebuilt caches reject withdrawn documents and revoked access; public output contains no restricted content. |
| Rebuild and delivery recovery | Delete Redis and rebuild hashes, IDs, publication status and access decisions from the retained sources and accepted log. Duplicate jobs, restart and lost responses produce no duplicate promotion/distribution; replay causes no external effects. |
| Custody and historical continuity | Re-hash retained receipt bytes at the destination; preserve receipt identities, original encodings/signatures where present, attribution and mappings. Missing bytes are reported unavailable, never replaced by a newer version. |
| Single-writer handover | Exercise the successor, race old/new commands and restart both. Fence the old command, CLI and direct-write routes for the migrated operation. Rebuild its projection from the accepted baseline, preserved versioned artifacts and common signed ledger. |
| Recovery after handover | Retain every newly accepted event and its current permission/withdrawal state. Recovery cannot re-enable an old writer from a stale database or resurrect spent delivery authority. Reconcile or retire each legacy consumer and backlog. |

The [Biz-kit decommission checklist][decommission] separates surface rehosting,
writer fencing, historical preservation and the standalone Mama deployment's
own succession record. Completion of TaskHost rehosting does not close the
other gates. This knowledge integration neither certifies Mama's retirement
nor makes it a prerequisite for an inert source import.

Record acceptance at exact source revisions with commands, outcomes and
retained evidence. The knowledge-specific import, admission, indexing and
delivery gates above remain unverified here. A documentation merge changes
the integration specification; operational authority moves only through the
verified handover for the affected workflow.

## Source contracts

- [Source authority and provenance](../../README.md).
- [Original October 30 decision][original], retained as historical evidence.
- [Biz-kit single-source-of-truth decision][ssot] and [storage contract][storage].
- [TaskHost rehosting][task-host], [retained task rules][salvage],
  [artifact custody][custody] and [decommission checklist][decommission].
- [SpruceGoose retirement and storage succession][retirement].

[original]: https://github.com/larsbx/bizops-kb/blob/ca356e34e6b1c4a2fb9f576c34196ca3bf13beee/docs/decisions/2026-10-30-source-custody-and-platform-storage.md
[ssot]: https://github.com/larsbx/biz-kit/blob/6414c58f50212e2cd47ed732400f859472b49d89/docs/architecture/2026-10-11-single-source-of-truth.md
[storage]: https://github.com/larsbx/biz-kit/blob/6414c58f50212e2cd47ed732400f859472b49d89/docs/architecture/2026-10-30-postgres-event-log-redis-consolidation.md
[task-host]: https://github.com/larsbx/biz-kit/blob/6414c58f50212e2cd47ed732400f859472b49d89/docs/architecture/2026-11-09-task-host.md
[rehost-pr]: https://github.com/larsbx/biz-kit/pull/356
[source-verifier]: https://github.com/larsbx/biz-kit/blob/6414c58f50212e2cd47ed732400f859472b49d89/apps/task_host/lib/task_host/blueprints/source_verifier.ex
[custody]: https://github.com/larsbx/biz-kit/blob/6414c58f50212e2cd47ed732400f859472b49d89/docs/architecture/2026-10-12-artifact-custody.md
[salvage]: https://github.com/larsbx/biz-kit/blob/6414c58f50212e2cd47ed732400f859472b49d89/docs/architecture/2026-10-20-sprucegoose-salvage.md
[decommission]: https://github.com/larsbx/biz-kit/blob/6414c58f50212e2cd47ed732400f859472b49d89/docs/architecture/2026-11-06-sprucegoose-decommission.md
[retirement]: https://github.com/larsbx/sprucegoose/blob/beb513dc8186d4c246383cf7d9c381eea6c849ad/docs/decisions/2026-10-30-biz-kit-retirement-storage.md
[hawala]: https://github.com/larsbx/hawala-core/pull/57
