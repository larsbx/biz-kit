-- SpruceGoose handover M0: what Mama holds, as counts only.
--
-- Run by the owner on mama, against the live SpruceGoose database:
--   psql -d spruce_goose_dev -f scripts/sprucegoose-mama-readonly.sql
-- (Mama's database is named in ops/mama-authority of larsbx/sprucegoose.)
--
-- Read-only and aggregate-only: one READ ONLY transaction that ends in
-- ROLLBACK, no row is ever selected, so no task text or identity leaves the
-- database. Tables a schema lacks are skipped. The counts are the baseline the
-- ledger import's parity check is held to (docs/architecture/
-- 2026-11-24-sprucegoose-mama-handover.md, M2).

\set ON_ERROR_STOP on
\pset footer off
BEGIN TRANSACTION READ ONLY;

SELECT to_regclass('public.projects') IS NOT NULL AS has_hierarchy,
       to_regclass('public.task_todos') IS NOT NULL AS has_todos,
       to_regclass('public.derivation_permits') IS NOT NULL AS has_permits,
       to_regclass('public.derivation_outcome_receipts') IS NOT NULL AS has_receipts,
       to_regclass('public.outbox_events') IS NOT NULL AS has_outbox,
       to_regclass('public.oban_jobs') IS NOT NULL AS has_oban,
       to_regclass('public.actors') IS NOT NULL AS has_actors,
       to_regclass('public.actor_grants') IS NOT NULL AS has_grants,
       to_regclass('public.certified_events') IS NOT NULL AS has_certified,
       to_regclass('public.ledger_import_receipts') IS NOT NULL AS has_imports,
       to_regclass('public.grandfathered_baselines') IS NOT NULL AS has_baselines
\gset

\if :has_hierarchy
\echo '== 1. Core counts (the parity table of ops/mama-authority/MIGRATION_PROGRESS.md) =='
SELECT (SELECT count(*) FROM projects) AS projects,
       (SELECT count(*) FROM roadmaps) AS roadmaps,
       (SELECT count(*) FROM workflows) AS workflows,
       (SELECT count(*) FROM workflow_tasks) AS workflow_tasks,
       (SELECT count(*) FROM task_todos) AS task_todos;

\echo '== 2. Tasks by state: everything not completed is open work the import must carry =='
SELECT state, count(*) AS tasks, max(updated_at) AS last_change
FROM workflow_tasks GROUP BY state ORDER BY state;
\endif

\if :has_todos
SELECT count(*) FILTER (WHERE NOT completed) AS open_todos, count(*) AS todos FROM task_todos;
\endif

\if :has_permits
\echo '== 3. Derivation permits: unconsumed ones are obligations of the worker move (decision 3) =='
SELECT action, state, count(*) AS permits FROM derivation_permits GROUP BY action, state ORDER BY 1, 2;
\endif

\if :has_receipts
SELECT outcome, count(*) AS receipts FROM derivation_outcome_receipts GROUP BY outcome ORDER BY 1;
\endif

\if :has_outbox
\echo '== 4. Queues that must drain before the fence =='
SELECT status, count(*) AS outbox_events, min(available_at) AS oldest_available
FROM outbox_events GROUP BY status ORDER BY 1;
\endif

\if :has_oban
SELECT queue, state, count(*) AS jobs FROM oban_jobs GROUP BY queue, state ORDER BY 1, 2;
\endif

\if :has_actors
\echo '== 5. Actors and grants (mapped to ledger principals and grants, never merged by name) =='
SELECT kind, count(*) FILTER (WHERE disabled_at IS NULL) AS active,
       count(*) FILTER (WHERE disabled_at IS NOT NULL) AS disabled
FROM actors GROUP BY kind ORDER BY 1;
\endif

\if :has_grants
SELECT role, count(*) AS grants FROM actor_grants GROUP BY role ORDER BY 1;
\endif

\if :has_certified
\echo '== 6. Certified history: kept byte-for-byte as inert audit data (checklist §3) =='
SELECT count(*) AS certified_events, max(sequence) AS last_sequence,
       count(DISTINCT stream) AS streams
FROM certified_events;
\endif

\if :has_imports
SELECT count(*) AS ledger_import_receipts, max(inserted_at) AS last_import FROM ledger_import_receipts;
\endif

\if :has_baselines
SELECT count(*) AS grandfathered_baselines FROM grandfathered_baselines;
\endif

\echo '== 7. Archive sizing: rows per table =='
SELECT relname AS table_name, n_live_tup AS approx_rows
FROM pg_stat_user_tables ORDER BY relname;

ROLLBACK;
