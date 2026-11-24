# Retirement cutover acceptance

Date: 2026-11-23. **Operator evidence template; no production action recorded.**
Use this with the [SpruceGoose checklist](2026-11-06-sprucegoose-decommission.md)
and the [Eatsbot checklist](2026-11-07-eatsbot-decommission.md). Fill identifiers
from observed sources. An empty field remains an open gate.
The [remediation validation record](2026-11-23-retirement-remediation-validation.md)
separates executed local checks from pending signed integration and production evidence.

## 1. SpruceGoose preflight

For an existing, governance-recorded archive, the read-only command is:

```sh
mix coop.preflight_writer spruce_goose --chapter C --archive DIR \
  --manifest-sha256 HEX --archive-event-id ID [--database-url URL]
```

It reopens the archive, validates its structure, required tables, digests,
binary COPY framing/counts and outbox fields, and checks the selected record
against a cryptographically verified canonical prefix with historical
governance checks. This does not re-adjudicate unrelated domain admission
rules. Retain the returned ledger head,
archive event/digest and earliest fence order if present. A positive pending
outbox count reports a remaining reconciliation prerequisite; passing preflight
does not authorize cutover.

The optional database URL compares the manifest's hostname/database labels;
it does not connect to the legacy database. The fence installer supplies these
labels from its actual target options. Record the actual port, cluster and
service identity separately: equal labels do not authenticate a database
instance. Preflight starts an EventStore-only read client with read-only
sessions, without starting the application/appender or repairing its indexes.
Keep the receipt outside the archive so it is not an unlisted archive file.

The older `mix coop.archive_writer --verify DIR --chapter C` is a file-hash and
ledger-digest check. Use strict preflight for cutover. Required missing/absent
tables have no override. Review the source inventory or a deliberate policy
change if an expected table legitimately does not exist.

### Reproducible acceptance before production

| Case | Required result |
| --- | --- |
| Valid synthetic archive and matching admitted record | Preflight succeeds with the exact selected event/digest and verified ledger head |
| Missing archive/manifest, malformed structure, corrupted or omitted file | Fail with an attributable error; no signing or database mutation |
| Incorrect manifest digest, wrong chapter/writer/event, invalid ledger prefix | Fail; a syntactically valid SHA-256 or supplied JSON record is insufficient |
| Missing/absent required table, malformed/truncated COPY, inconsistent rows/fields | Fail; file hashing alone cannot establish completeness |
| Missing outbox payload/identity/retry columns or required non-null values, inconsistent row count or dispatch metadata | Fail even when file hashes were recomputed; an intact preserved backlog reports reconciliation still required |
| New fence before any admitted archive | Admission refuses it; the rejected append leaves the ledger unchanged |
| Archive changed between preflight and signing/install | The action's fresh check refuses it |
| Existing database fence names a different selected order | Refuse; do not silently reuse unrelated installed evidence |
| Derived fence order reuses the event ID with a different chapter, writer, type or sequence | Refuse before connecting to the legacy database; compare the consumed identity with canonical evidence |

Pure validation tests use synthetic files and inert inputs without keys,
`LogCase`, application boot or database connections. Separately authorized
disposable-database acceptance must restore all seven table copies, compare
rows and provenance, exercise the real direct/CLI admission paths, failed
transaction rollback, exemptions, concurrency and replay. Record exact source,
toolchain and results; do not count unrun tests as passing.

The boot-free acceptance entry point is:

```sh
MIX_ENV=test mix run --no-start scripts/retirement_preflight_acceptance.exs
```

Add `--restore` with `RETIREMENT_TEST_DATABASE_URL` pointing at an explicitly
disposable local PostgreSQL server on a nondefault port to run the seven-table
binary COPY round trip and standalone reader checks. The latter reuse a
committed signed non-governance vector to exercise the real native verifier,
tamper refusals and pinned-head checks without generating a signature.
The entry point never invokes the normal `mix test` alias, which drops the
configured event store, or the normal test helper. Signed governance admission
and installation regressions remain in the normal isolated integration suite.
Consolidation now includes the same boot-free acceptance step against its
disposable service; record the hosted result at the exact reviewed revision.

## 2. SpruceGoose operational sequence

1. **Inventory and parity.** Identify chapter, source database/service and
   reviewed source revision. Inventory target projects and ownerless projects
   through the existing authenticated, governance-signed chapter GET routes;
   reconcile these with all live legacy projects. `mix coop.owner.backfill`
   creates governance events and is not an inventory/dry-run command. Backfill
   each retained project's eligible owner only under separate authorization.
   Retain `ledger replay-status` as legacy certified-to-row consistency/lag
   evidence, then compare the retained source identities and fields with the
   TaskCore projection at identified source snapshot/certified position and
   target canonical ledger head. Record reviewed identity mappings and every
   missing/different item's disposition, including deliberate retirement;
   neither matching counts nor legacy replay-status alone proves this parity.
   The [checklist](2026-11-06-sprucegoose-decommission.md#2-authority-cutover)
   identifies the existing implementation paths; no comparison tool is implied.
   Map retained commands and consumers to the task host. Preserve native
   sessions and their atomic revocation; `/mcp`, its OAuth issuer and the
   explicitly discarded domains stay retired.
2. **Settle and quiesce.** Stop new task-row, certified/ShadowEvents and
   actor-registry work from CLI/service and background producers. Drain outbox
   delivery, or assign every item that will be preserved a reconciliation
   owner and disposition. Then stop delivery and provenance-file changes and
   settle all in-flight transactions. Keep every source writer stopped until
   the fence commits, and archive bytes stable throughout verification and
   cutover. Do not infer quiescence from an archive timestamp or a
   repeatable-read snapshot.
3. **Preserve.** Export the final snapshot and referenced constitution/SOP
   bytes; record its exact manifest digest under governance. Retain custody
   bytes outside the log and verify them against receipts. Preserve the final
   outbox state and the dispositions from step 2. If any source row changes
   after the snapshot, repeat the final snapshot and verification sequence;
   do not drain or edit the source after export and reuse the old archive.
4. **Verify durable copies.** Select storage, access, retention and restore
   ownership. Run strict preflight against each retained copy and keep the
   results. Rehashing proves current content, not future durability or that no
   source commit was omitted before export.
5. **Approve and fence.** Review the complete receipt below. Only after
   operational authorization, use the fence CLI with the same archive,
   manifest hash and archive event ID, plus the identified database and reason.
   It checks before signing and again at installation. The signed fence schema
   is unchanged: archive selection is retained in the receipt, not a new
   signed payload field. Keep privileged DDL/trigger changes controlled.
6. **Prove the result.** Check all covered old commands refuse writes, reads
   still work, native sessions/migrations retain intended behavior, and replay
   reproduces accepted projections. Verify restart and recovery while the old
   writer remains stopped. A rollback must preserve every newly accepted
   event; restoring an old writable snapshot is not an automatic rollback.

### Cutover receipt template

| Evidence | Value / location |
| --- | --- |
| Operator/reviewer, authorization reference, observation time | Pending |
| Chapter; source host/port/cluster/database/service; application/build revision | Pending |
| Target host, retained commands/consumers, legacy-to-target project mapping and eligible owner inventory | Pending |
| Legacy replay-status; separate retained-field comparison with source snapshot/certified position, target ledger head and discrepancy dispositions | Pending |
| Quiescence start; writer inventory; in-flight completion evidence | Pending |
| Archive directory/copy locations; manifest SHA-256; archive event ID | Pending |
| Required-table inventory; original bytes/provenance/custody verification | Pending |
| Outbox count and exact pending-item disposition/owner | Pending |
| Per-copy strict preflight report and verified ledger head | Pending |
| Storage/retention/restore owner and successful restore receipt | Pending |
| Selected fence event; installed database fence identity | Pending |
| Refusal/exemption, restart and post-fence replay results | Pending |
| Recovery plan preserving post-cutover events; unresolved exceptions | Pending |

## 3. Mama succession inventory

The standalone [August 2 migration record](https://github.com/larsbx/sprucegoose/blob/beb513dc8186d4c246383cf7d9c381eea6c849ad/ops/mama-authority/MIGRATION_PROGRESS.md)
records Evergreen stopped and Mama becoming authoritative. It is historical
evidence for that move. The later [retirement/storage decision](https://github.com/larsbx/sprucegoose/blob/beb513dc8186d4c246383cf7d9c381eea6c849ad/docs/decisions/2026-10-30-biz-kit-retirement-storage.md)
keeps Mama-to-Biz-kit implementation and cutover gated. Neither establishes a
current retirement of Mama.

Before declaring standalone retirement, obtain a new owner-approved record in
`larsbx/sprucegoose`, with these inventory rows and the cutover receipt above:

| Inventory | Required disposition |
| --- | --- |
| Running Mama release/revision, PostgreSQL identity, service/authority markers | Fresh observation; exact successor and single-writer boundary |
| Local CLI, Evergreen/other bridges, sockets, dashboards, SOP/runtime consumers | Repoint retained consumers; explicitly retire unused paths |
| Projects, tasks, grants, open work, permits, terminal receipts, custody | Stable identities/provenance; named surviving owner or recorded retirement |
| Queue/retry/schedule work and unknown external effects | Drain/reconcile or retained durable owner; cache loss cannot authorize effects |
| Original certified bytes, stream links, archives and restored copies | Verified preservation and restricted retention, without invented signatures |
| Old/new writer races, restart, replay and recovery | Old service stays fenced; every newly accepted event survives recovery |
| Services, deployments, credentials and repository history | Disable/remove only after accepted succession and retention evidence |

Retain only capabilities already selected for Biz-kit. `Revise` stays dropped:
task text is immutable and changes use a new task or a change suggestion.
The standalone inventory does not reopen discarded boards, inbox, deployment,
runtime-shadow or provenance domains as implementation requirements.

## 4. Eatsbot's distinct operational remainder

[R0](2026-11-16-eatsbot-r0-inventory.md) records the owner's disposable
`adder-ws` stack, no customer data, and approved stop/removal of legacy apps.
There is no archive/drain or trigger-fence prerequisite for that test stack.
For any other legacy copy, first inventory actual obligations and data; the
test-stack exception does not establish that every copy is empty.

Source retirement is merged in [#426](https://github.com/larsbx/biz-kit/pull/426)
and standalone Fly-file removal in [eatsbot #41](https://github.com/larsbx/eatsbot/pull/41).
Retain separate evidence of the actual running replacement revision and host
health, Fly app/database disposition if present, credential revocation, and
read-only repository archival after retention. Adder-ws activation still needs
the [host/tailnet acceptance record](../adder-ws-cd.md); HTTP 202 and a green
trigger job do not establish deployment. These actions are not recorded as
executed by this runbook.
