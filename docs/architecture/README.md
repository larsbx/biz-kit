# biz-kit architecture

What is delivered and what comes next: [the roadmap](../roadmap.md).

The consolidation target is one signed business-event ledger and rebuildable
domain views. The imported histories and existing identifiers remain intact.

- [One source of truth — 2026-10-11](2026-10-11-single-source-of-truth.md): current
  direction, common command/write path, removal targets, and cutover proof.
- [Integration comparison — 2026-10-09](2026-10-09-integration-decisions.md):
  baseline implementation evidence and tradeoffs. Its recommendation to retain
  independent authorities is superseded by the consolidation target.

- [First common-ledger task command](2026-10-11-first-ledger-task-command.md): notes
  retirement, signed baseline and scoped grant, append-time proposal admission,
  retry/replay contract, verification, and the next production cutover boundary.
- [Task timing and agent suggestions — draft](2026-10-18-task-timing-and-suggestions.md):
  calendar timing facet, suggester grants, suggestion/accept events and their
  admission rules, with a Quint model. Ledger events implemented; the change feed below carries them to clients.
- [Delegated task changes](2026-10-18-task-delegation.md): operators delegate
  classes of routine timing changes or task creation to agents, within limits
  and a budget. Implemented; modelled in the same Quint spec.
- [Change feed](2026-10-18-change-feed.md): a project's tasks, suggestions and
  delegations pushed to clients as frames, resumable from a cursor, with SSE
  framing, served by SpruceGoose to readers holding a ledger grant for the
  project. Agents sign their reads; people use a session.
- [Identity](2026-10-18-identity.md): biz-kit's own principal IDs, a
  replaceable sign-in provider (WorkOS first), explicit identity bindings and
  local sessions. The ledger keeps all authority.
- [Native sign-in](2026-10-21-native-sign-in.md): apps sign in through the
  system browser (RFC 8252, PKCE) and get the same biz-kit session as a bearer
  token, which dispatch's `/v1` accepts.
- [Deciding on suggestions](2026-10-18-decide.md): the first end-to-end
  workflow. A person accepts or declines an agent's suggestion in the web
  view; the command is signed by a key held in their browser.
- [Self-service device enrolment](2026-10-19-device-enrolment.md): a device
  requests access and proves its key; an administrator approves the code with
  the governance key (`mix coop.enrol`).
- [Device revocation](2026-10-19-device-revocation.md): people revoke their
  own devices from any device still enrolled; administrators revoke any grant
  with the governance key (`mix coop.revoke`).
- [Offboarding](2026-10-19-offboarding.md): one governance-signed event per
  project ends everything a principal holds there; `mix coop.offboard` does
  every project at once.
- [Editing before accepting](2026-10-19-amend.md): a person edits a
  suggestion's timing, or a create suggestion's title and description, and
  accepts it as edited; the ledger records it as `amended`.
- [Lifecycle in the view](2026-10-19-lifecycle.md): a person proposes,
  acknowledges the SOP, queues and marks ready from the web view, citing
  receipts already in custody; revokes delegations they made; and sees
  decided suggestions, withdrawals included.
- [Uploads from the browser](2026-10-19-uploads.md): a device stores the SOP
  or an input a task names, checked against the SHA-256 it computed, and
  records custody of it.
- [Cluster](2026-10-19-cluster.md): several nodes as one service over
  distributed Erlang; the ledger's appender and the in-memory stores run
  once per cluster, and feed notifications reach every node.
- [Task core](2026-10-20-task-core.md): the task and workflow rules as a
  dependency-free app (`apps/task_core`) any application can vendor, behind
  two host ports; one lifecycle contract and DAG shared with SpruceGoose.
- [Hierarchy and blueprints](2026-10-20-hierarchy-and-blueprints.md): a
  project's roadmaps and workflows as a reviewed blueprint in git, applied by
  governance from a pinned source (`mix coop.blueprint`); an operator runs a
  workflow, creating its tasks with their Definitions of Done and
  predecessors. SpruceGoose's design reviewed point by point.
- [Workflows in the view](2026-10-20-workflow-view.md): a project's feed
  carries its workflows; a person runs one from the page, and each task says
  which workflow and step it came from.
- [Readiness for a workflow run](2026-10-20-run-readiness.md): an
  administrator defines readiness for a run's tasks in one signed batch, the
  blueprint's predecessors and input names filled in; the page shows each
  run's progress.
- [What the ledger keeps from SpruceGoose](2026-10-20-sprucegoose-salvage.md):
  todos that gate completion, no predecessor cycle across a project, and SOP
  versions that never go back; with Quint models. The rest of SpruceGoose's
  domain is not migrated.
- [Rate limits](2026-10-19-rate-limits.md): every request is limited per
  client before its body is read, in one of three buckets chosen by path;
  clients behind trusted proxies are told apart by `x-forwarded-for`.

Application contracts remain under `apps/`. Start with
[CoopSubstrate's normative substrate](../../apps/coop_substrate/SUBSTRATE.md),
[SpruceGoose's authority planes](../../apps/spruce_goose/docs/authority-planes.md),
and its [documented current state](../../apps/spruce_goose/docs/current-state.md).
- [Dispatch capability document](2026-10-20-dispatch-capability-document.md):
  what dispatch offers a role assignment, as Ed25519-signed canonical bytes the
  d-patch field app verifies against a pinned key. An attestation for the
  client, not authority; retired when dispatch's roles become ledger grants.
- [Company-structure primitive audit — 2026-10-20](2026-10-20-primitive-audit.md):
  every party, role, seat, delegation, ownership and decision model across
  biz-kit and the remaining repos, compared with Keel; conflicts to decide,
  what Keel lacks, defects found, and a recommended order.
