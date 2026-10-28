# SchoolOps domain guardrails

SchoolOps is a biz-kit domain app, not a standalone task management system.
Reuse `task_core` for workflows, lifecycle, DAG, readiness, DoD and reviews;
reuse the common ledger for admitted changes and platform identity/grants for
school roles. Do not implement a second school task writer or implicit grants.
School-specific features belong here: curricula, lesson prerequisites,
assessment rules, class scheduling and later private learner workflows.

The bundled educational materials are a pinned upstream source snapshot.
Before changing them read `priv/content/AGENTS.md`,
`priv/content/docs/curriculum-model.md` and
`priv/content/docs/trivium-quadrivium.md`. Preserve stable IDs, explicit
material readiness and evidence criteria. Music remains excluded, and
Common Core is not the organizing framework. Material readiness, staff task
completion and student mastery must never be equated.

Do not commit learner records, class-specific assignment links or third-party
content without rights. Treat proposed workflow definitions as untrusted until
the shared platform verifies provenance and scoped authorization; do not
serialize Elixir modules or call `Code.eval_*` for external definitions.
