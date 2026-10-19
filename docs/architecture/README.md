# biz-kit architecture

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
- [Cluster](2026-10-19-cluster.md): several nodes as one service over
  distributed Erlang; the ledger's appender and the in-memory stores run
  once per cluster, and feed notifications reach every node.
- [Rate limits](2026-10-19-rate-limits.md): every request is limited per
  client before its body is read, in one of three buckets chosen by path;
  clients behind trusted proxies are told apart by `x-forwarded-for`.

Application contracts remain under `apps/`. Start with
[CoopSubstrate's normative substrate](../../apps/coop_substrate/SUBSTRATE.md),
[SpruceGoose's authority planes](../../apps/spruce_goose/docs/authority-planes.md),
and its [documented current state](../../apps/spruce_goose/docs/current-state.md).
