# SpruceGoose decommission checklist

Originally written 2026-11-06; reconciled 2026-11-23. Status: **retained paths
rehosted, archive and fence safeguards implemented; production cutover and
Mama succession still lack accepted execution evidence.** This checklist records the conditions for
removal. A documentation or source merge does not satisfy an operational gate.
Sources: [one source of truth](2026-10-11-single-source-of-truth.md),
[what the ledger keeps from SpruceGoose](2026-10-20-sprucegoose-salvage.md),
[legacy grant history](2026-10-21-legacy-grant-history.md),
[first ledger task command](2026-10-11-first-ledger-task-command.md),
[native sign-in](2026-10-21-native-sign-in.md),
[project ownership](2026-11-02-project-ownership.md),
[consolidation](2026-10-30-postgres-event-log-redis-consolidation.md) and
[deploy](../deploy.md). The original inventory used main `a085ae0f`; the current
source review used main `40d49e85` and archive PR #443 at `1f3a9ac7`, followed by
the strict preflight remediation. Use the
[cutover acceptance runbook](2026-11-23-retirement-cutover-acceptance.md) for
the exact evidence to retain.

## Definition

SpruceGoose is decommissioned when all four hold:

1. **Surfaces.** Every live surface it serves is rehosted (§1).
2. **Authority.** Its three writers are fenced and a replay proof passes (§2).
3. **History.** Its retained history is preserved as inert audit data that
   grants no authority (§3).
4. **Mama.** The standalone production deployed from the `sprucegoose`
   repository (`ops/mama-authority`) meets its own succession and
   verified-retirement record. Its August 2 Evergreen-to-Mama migration
   completion is not evidence of a subsequent Mama-to-Biz-kit retirement.
   The runbook supplies a succession inventory and receipt template; the
   accepted standalone record remains owned by the `sprucegoose` repository.

Only then are `apps/spruce_goose`, its release wiring and its settings removed.

## 1. Surfaces to rehost

Rehosted on the task host on 2026-11-09, with the owner's decisions on
sessions and `/mcp` ([task host](2026-11-09-task-host.md), which tracks each
row's gate).

| Surface | Depends on it | Requirement | Gate |
| --- | --- | --- | --- |
| `/auth`: WorkOS sign-in, native sign-in exchange, `BIZKIT_IDENTITY_BINDINGS` | d-patch; Dispatch's `BizKitSession` verifier | One authentication entry point outside SpruceGoose | d-patch native sign-in and Dispatch portal acceptance pass against the new host |
| `identity_native_sessions` and `SpruceGoose.Web.NativeSessionStore` | Every signed-in native device | Move the store and its rows, or end every session and require sign-in again. *Decided: kept* (store in `biz_kit_identity`, same table). Revocation stays atomic | Atomic native-session revocation tests pass on the new store |
| OAuth2 issuer for MCP clients (`SPRUCE_GOOSE_OAUTH_ACTOR_BINDINGS`, `OAUTH2_SIGNING_SECRET`) | MCP clients | *Dropped with `/mcp`* (task host decision 3). Nothing else used it | Recorded |
| Task web view and API: commands, SSE feed, tasks, run readiness, project ownership, devices, enrolment, grants, offboarding, administrators, artifacts, blueprints | Operators | Already thin over `CoopSubstrate`; rehost on a ledger-only host | The browser workflow and HTTP suites pass against the new host |
| `/mcp` (AshAi over Ash resources) | Agents | Rebuild on task commands, or drop. *Decided: dropped*, with the OAuth2 issuer | Decided and recorded |
| `orchestration` release and `SpruceGoose.ReleaseTasks.migrate/0` | Deployment | The new host also creates and initializes the **ledger's** event store | `scripts/release-smoke.sh` equivalent passes without SpruceGoose |
| `COOP_ARTIFACT_DIR` | Ledger `ArtifactCustody` receipts | Receipts reference bytes outside the log; retain them at the task host's custody location | Every custody receipt's bytes re-hash to their recorded digest at the new location |
| `ARTIFACT_STORE_ROOT` (`/var/lib/sprucegoose/artifacts`) | SpruceGoose's legacy artifact store | Inventory and preserve required historical bytes separately from ledger custody | Every retained legacy reference has a preservation destination and verification receipt |
| CLI commands that sign ledger events | Operators | Keep them as `mix` tasks; legacy-writer commands go with the writer | Each retained command has a `mix` task and test |

## 2. Authority cutover

Writers to fence: the live task-row writer, the `certified_events` /
`ShadowEvents` writer, and the legacy `Actors` registry.

| Condition | Current disposition | Gate |
| --- | --- | --- |
| Ledger coverage of retained paths | Lifecycle, todos, predecessor cycles, SOP versions, readiness, hierarchy and blueprints are on the ledger. *Met (2026-11-23):* `Blueprints.Applier` is replaced by `TaskBlueprintAppliedV1` (`mix coop.blueprint`); `Checks.HasRole` retires with the Ash resources it guards, ledger grants deciding instead; `Revise` is not migrated (owner decision, §4) | Each retained approval path admitted by a signed ledger event, with a refusal test |
| Legacy task import | `SpruceGoose.Ledger` import receipts and baselines | Baseline events never overwrite existing ledger tasks |
| Project owners | Authenticated, governance-signed reads list target projects and ownerless projects. Actual backfill appends principal-kind/grant/owner events; the production inventory has not been accepted here | Every live legacy project is mapped to its retained target or explicit retirement, and every retained project has an eligible accountable owner |
| Dual-read parity | `ledger replay-status` checks legacy certified-to-row consistency and lag. A separate read-only source-to-TaskCore comparison is still required | Identify both source and target heads/snapshots, compare retained identities and fields, and explain every difference; the uncertified state moves of migration `20261021090000` are one known legacy discrepancy |
| Signed fence | *Implemented, not ordered in production:* the CLI requires the archive directory, exact manifest digest and archive event ID. It runs strict preflight before signing; installation rechecks the archive and verified governance order. The admitted prefix must contain an archive before a new fence order. Statement triggers cover the inventoried database tables in one transaction, leaving `public.identity_native_sessions` and `public.schema_migrations` writable | A covered command cannot succeed through a row write or the old writer; failed admission changes no state. Existing installed order identity must agree. Configuration rollback is not a fence |
| Replay proof | Not started | Replay after the fence reproduces the projections |

The order at cutover is: owners backfilled; dual-read parity explained; all
legacy writers quiesced and in-flight transactions settled; final history
copied and recorded; every durable copy verified; fence; post-fence replay.
Keep the source quiescent from the final snapshot through installation.
Repeatable-read gives a consistent snapshot, not preservation of later commits.

For inventory, the existing chapter routes are `GET /api/v1/chapters/:chapter_id/projects`
and `GET /api/v1/chapters/:chapter_id/ownerless_projects`; they require authenticated,
governance-signed reads. Reconcile them with the live legacy project inventory:
an empty ownerless list alone cannot establish that every legacy project was
migrated. The [ownerless controller](../../apps/task_host/lib/task_host/web/project_ownership_controller.ex)
only lists; `mix coop.owner.backfill` signs and submits governance events and
must not be used as an inventory or dry-run command.

[`TaskProjector.status/0`](../../apps/spruce_goose/lib/spruce_goose/kernel/task_projector.ex)
compares stored `replay_projections` with `workflow_tasks` and reports the
`certified_events` lag. It does not compare them to the common ledger's
[`TaskCore` projection](../../apps/coop_substrate/lib/coop_substrate/projections/tasks.ex).
Retain a read-only comparison report with source database/snapshot and certified
position, target canonical ledger head, reviewed identity mappings, retained
task/hierarchy/owner/grant/DoD/TODO/dependency/SOP/artifact fields, and a disposition
for every missing or different item. Counts and a successful legacy replay-status
are useful supporting evidence, not cross-authority parity acceptance. No new
comparison command or completed production comparison is claimed here.

`mix coop.preflight_writer` is a read-only check of archived bytes and verified
ledger records. It does not authorize cutover or establish production source
quiescence, storage durability, owner backfill or outbox reconciliation.
The signed fence payload remains `writer` and `reason`; it does not sign a new
archive reference. Retain the selected archive event/digest and fence event
together in the operational receipt. The fence CLI and installation check
that selection; the ledger admission gate enforces prior archive-record
existence. Nothing on the ledger unfences. Database owners can remove or
disable triggers, and tables created later need another installation; the
cutover plan must control those privileges and schema changes.

## 3. History to preserve as inert audit data

None of it converts into ledger authorization.

- **Legacy grant registry,** including closed grants and `grant history`.
  Grants deleted before #50 cannot be reconstructed.
- **`certified_events`:** the original ETF bytes and their content identities.
- **`notes` and the old `events` table:** inventory, keep what is needed, and
  record digests and where the copies are kept. Never apply a generated Ash
  migration that drops them.
- **Ledger import receipts, grandfathered baselines, and the constitution and
  provenance bytes** that records reference (`priv/constitution/adopted.json`,
  the Systemwide SOP digest).
- **`outbox_events`:** drain or reconcile the backlog before the dispatcher and
  Oban are removed.

*Implemented; production execution remains pending (`CoopSubstrate.HistoryArchive`):*

    mix coop.archive_writer spruce_goose --database-url postgres://… --out DIR \
      --file <the deployment's Systemwide SOP> --chapter C

- **What leaves:** `actor_grants` (closed grants and grant history included),
  `certified_events`, `notes`, `events`, `ledger_import_receipts`,
  `grandfathered_baselines` and `outbox_events`. They are copied from one
  repeatable-read snapshot as PostgreSQL binary `COPY`, which is lossless:
  the ETF bytes stay byte for byte, and a copy restores row for row into a
  table of the recorded column types.
- **Files:** `priv/constitution/adopted.json` is copied, and so is each
  `--file`. The Systemwide SOP lives at a deployment path, so it is passed
  explicitly.
- **Manifest:** `manifest.json` lists every table with its row count, column
  types, SHA-256 and size, and every file with its digest. A table the
  database lacks is listed as absent by export. Strict preflight refuses an
  absent or omitted required table; there is no absent-table bypass. Resolve
  the source inventory or review a policy change before proceeding.
- **Outbox:** undispatched `outbox_events` rows stop the export until they
  are drained. `--allow-undispatched-outbox` keeps them in the archive
  instead, and the manifest records how many there are. Strict preflight
  checks COPY framing/counts and outbox status/timestamp fields. An intact positive backlog
  still requires a named reconciliation owner and disposition before cutover.
- **Ledger record:** governance signs `LegacyHistoryArchived` (`writer`,
  `manifest_sha256`). It records the digest and grants nothing.
  `mix coop.archive_writer --verify DIR --chapter C` re-hashes an archive and
  checks that the ledger records it. The strict cutover check is:

      mix coop.preflight_writer spruce_goose --chapter C --archive DIR \
        --manifest-sha256 HEX --archive-event-id ID

  Retain its verified ledger head, selected archive event and manifest digest,
  and earliest fence order when present. The fence command requires the same
  three archive arguments and rechecks them before signing and installation.
- **Where copies are kept:** decided at cutover. Each copy is checked with
  strict preflight and its verification receipt retained. Storage retention,
  restore access and referenced deployment SOP/custody bytes remain operational
  evidence requirements.

## 4. Not migrated

They are retired with the writer, per the salvage decision: `Revise` (TOML
revisions of a roadmap's, workflow's or task's text; owner decision
2026-11-23: a task's text stays as created, and a change is a new task or a
change suggestion); wait notes; the
blocked, impact and critical-path views; inbox captures; boards, columns and
filters; runtime shadows; derivation permits and outcome receipts; release
provenance; the deployment domain; `Kernel.Constitution` (callers only in its
own test); Oban.

## Open

- **First governance seat held by a person.** The salvage decision deferred
  it to Keel. Project ownership now records principal kinds
  (`TaskPrincipalKindDeclaredV1`, declared `human` for owners), but this
  document does not establish that the rule is enforced for governance seats.
- **Exact-revision acceptance.** At archive PR #443 head `1f3a9ac7`,
  [Consolidation run 45196466886](https://github.com/larsbx/biz-kit/actions/runs/45196466886)
  passed, including the common-ledger, orchestration, task-host and browser
  steps. This supersedes the old blanket claim that these checks were red.
  The [remediation validation record](2026-11-23-retirement-remediation-validation.md)
  records 57 passing local checks, including seven-table restore and the
  read-only client. Signed integration and hosted acceptance remain pending;
  earlier green checks do not establish the new behavior.
- **Operational closure.** Owner inventory, explained parity, source
  quiescence, final durable archives, outbox disposition, artifact-custody
  verification, production fence/replay and Mama succession remain to be
  evidenced through the runbook. None is marked complete by this checklist.
