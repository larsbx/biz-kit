# SpruceGoose: handing Mama's authority to biz-kit

Date: 2026-11-24. Status: **decided; M0 tooling and the fence ready, nothing
run on Mama.** Completes the
[SpruceGoose decommission checklist](2026-11-06-sprucegoose-decommission.md)
after its surfaces moved to the [task host](2026-11-09-task-host.md). Sources:
`larsbx/sprucegoose` at `beb513d` (`ops/mama-authority/README.md`,
`MIGRATION_PROGRESS.md`, `docs/current-state.md`,
`docs/decisions/2026-10-30-biz-kit-retirement-storage.md`).

## Where authority is today

Mama runs the standalone SpruceGoose release (deployed commit `3a2dc63`, per
`docs/current-state.md`) on its own PostgreSQL. Ash/PostgreSQL owns projects,
roadmaps, workflows, tasks, lifecycle, actors, grants, receipts, permits and
evidence. Evergreen's `sprucegoose` CLI reaches it through an owner-only Unix
socket forwarded over SSH (`sprucegoose-remote-client.service`). A bounded
Oban worker (queue `derivations`) runs one action, `verify_artifact`. At the
August cutover Mama held 14 projects, 24 roadmaps, 33 workflows, 425 tasks and
64 todos.

Biz-kit's `apps/spruce_goose` is an imported copy that serves only the
`adder-ws` test stack, whose databases are recreated on every start. So
retiring SpruceGoose means moving Mama's live authority, not deleting an app.

## Decisions (owner, 2026-11-24)

| # | Decision | Consequence |
| --- | --- | --- |
| S1 | **Target: another host**, named by the owner | Biz-kit's `orchestration` release (ledger and task host) runs there durably, not on `adder-ws` |
| S2 | **Import Mama's data into the ledger** | A governance-signed import with stable IDs and provenance (`SpruceGoose.Ledger` import receipts and grandfathered baselines), checked against a frozen dump. Original rows and `certified_events` bytes are kept as inert audit data. No old signature is fabricated |
| S3 | **Move the derivation worker to the shared worker** | `verify_artifact` re-hosted on biz-kit's durable-intent worker with receipts; then Oban goes |
| S4 | **Replace the CLI with biz-kit's mix tasks and the task host** | Operators use the signed `mix coop.*` tasks and the task host's web view and API; the `sprucegoose` CLI and its SSH bridge retire |

## Handover steps

Each step names its gate. Steps on `mama` or `evergreen` need the owner's
shell there; this environment cannot reach either host.

| Step | Work | Gate | Who |
| --- | --- | --- | --- |
| M0 inventory | Run [`scripts/sprucegoose-mama-readonly.sql`](../../scripts/sprucegoose-mama-readonly.sql) on Mama: core counts, tasks by state, open todos, permits by state, outbox and Oban queues, actors and grants, certified history, rows per table. Read-only, counts only | Output recorded with the date and Mama's deployed commit | Owner, on mama |
| M1 target | Durable `orchestration` deployment on the S1 host: its own PostgreSQL for the ledger and task host, `TaskHost.ReleaseTasks.migrate/0`, governance key ceremony, `COOP_ARTIFACT_DIR` | `scripts/release-smoke.sh` passes against it; every custody receipt re-hashes at its artifact location | Owner (host), with deploy files from biz-kit |
| M2 import rehearsal | Restore a fresh frozen Mama dump on the target, run the ledger import from it, compare | Imported counts equal M0's; each retained approval path admitted by a signed event with a refusal test (checklist §2); every live project has an owner; replay reproduces the projections | biz-kit, then owner on the host |
| M3 consumers | Map every `sprucegoose` CLI command evergreen uses to a `mix coop.*` task or a task-host call (S4) | Each retained command has a mix task and a test; nothing an operator needs is CLI-only | biz-kit |
| M4 worker | `verify_artifact` on the shared worker (S3), from durable intent with receipts | A permit is consumed exactly once across a worker restart; outcomes match Oban's for the same permits | biz-kit |
| M5 switch | Stop writes on Mama; drain `outbox_events` and `oban_jobs`; final dump; import the delta; then fence: governance signs `LegacyWriterFenced` for `spruce_goose` and `mix coop.fence_writer spruce_goose` installs it on Mama's database. Evergreen's bridge is disabled | A write to Mama's database is refused after the fence (`WriterFenceTest`, spruce_goose case); M0 counts plus the delta equal the ledger's; rollback documented as an authority move that keeps every new ledger event | Owner, on mama and the target |
| M6 retire | Archive Mama's database and `certified_events` bytes read-only with digests (§3); remove `apps/spruce_goose`, its release wiring and settings from biz-kit; archive `larsbx/sprucegoose` | Proof Bank, formal coverage and CI updated as for Eatsbot R6 | biz-kit, then owner |

## Ready now

- **The fence covers SpruceGoose.** `CoopSubstrate.WriterFence` admits
  `spruce_goose` (one order fences the database its three writers share: task
  rows, certified events, actor registry), tested with SpruceGoose's tables and
  per-writer orders.
- **M0's check.** `scripts/sprucegoose-mama-readonly.sql`, run against a
  database migrated from `apps/spruce_goose`: every section resolves, and it
  ends in `ROLLBACK`.

## Open

- **S1's host.** Name the host, and M1's deployment files follow.
- **Mama's PostgreSQL major.** `ops/mama-authority/recovery/README.md` warns
  that the version must be read off the running server; the import rehearsal
  restores into the target's PostgreSQL.
