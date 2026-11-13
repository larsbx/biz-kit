# Proof Bank AgentCore × TaskCore execution-admission correspondence

Date: 2026-11-13. Status: **candidate runtime conformance, not a formal
implementation-refinement proof**.

## Intended behavior, grounded in actual code

- `TaskCore.AgentRuns` admits operator-signed agent-run *intent* against the
  current task, its version, source and DoD digest, current operator and
  suggester grants. `authorized?/3` additionally requires *independent*
  current task-read and execute grants.
- `AgentCore.Profiles.resolve/3` checks an approved trusted registry,
  current immutable manifest digest and reviewed adapter module. A profile
  reference does not create an executable permission.
- `AgentCore.Preflight.prepare/4` constructs a **candidate**, not a
  launch lease, from an authorized run, fixed task ticket and host-supplied
  data classifications and budgets.
- `TaskCore.Dispatcher.deliver/2` calls `prepare` before durable register
  and claim and again **after the CAS claim**; changed authority fences the
  lease instead of launching an adapter.
- `AgentOpsStore.Coordinator` implements this bridge with a persistent
  PostgreSQL attempt projection in explicit **staging only**. The launch
  adapter and attempt store never become the signed business-event authority.

These boundaries are implemented across
`apps/task_core/lib/task_core/agent_runs.ex`,
`apps/agent_core/lib/agent_core/{profiles,preflight}.ex`,
`apps/task_core/lib/task_core/dispatcher.ex`, and
`apps/agent_ops_store/lib/agent_ops_store/{coordinator,postgres}.ex`.

## New adversarial acceptance at the actual boundary

`apps/agent_ops_store/test/dispatch_integration_test.exs` already contains
real PostgreSQL competing-claim, revocation-after-claim, ambiguous-launch,
backend termination, and two-adapter tests. This increment adds three
controlled *between-claim-and-launch* changes:

| Change after CAS claim | Required observable behavior |
| --- | --- |
| Task version changes | `:stale_agent_run_task` on recheck; no launch; durable `cancel_requested` |
| Operator grant revoked | `:agent_run_operator_revoked`; no launch; durable fence |
| Approved profile manifest changes without matching signed digest | `:execution_profile_digest_mismatch`; no launch; durable fence |

Each test injects the change at the **second** host context read, after the
durable claim. No production code is bypassed in the test: the actual
`Coordinator.deliver`, `TaskCore.AgentRuns.authorized?`,
`AgentCore.Preflight.prepare`, `Dispatcher.deliver`, and PostgreSQL
transition path run. The fixture uses process-local simulated TaskCore replay,
not an independently authenticated, durable, source-bound ledger event; do
not treat it as proof of live governance identity or production authority.

## Formal obligations derived from the implementation

Define a guarded relationship among:
`SignedRunIntent`, `CurrentTask`, `CurrentOperatorGrant`,
`CurrentReadGrant`, `CurrentExecuteGrant`, `ApprovedProfileDigest`,
`CASLease`, `AdapterLaunch`, and `CandidateResult`.

- **AT-1:** a launched effect must have a current authorized run, matched
  task source/version, both independent grants and a matching approved profile
  at the prelaunch check.
- **AT-2:** an intervening mutation to any of those requirements must prevent
  a launch and persist a fenced attempt when discovered post-claim.
- **AT-3:** a late worker cannot submit candidate bytes after its lease is
  cancelled or its epoch superseded.
- **AT-4:** lease expiry / lost backend reply does not license a retry without
  independently verified external reconciliation.
- **AT-5:** a produced candidate never implies approval, completed task,
  accepted proof or business side effect.

`formal/lean/BizKitAgentTask.lean` models the exact two-phase
preflight/claim/recheck guard and contains an unguarded counterexample.
`formal/lean/BizKitLeases.lean`, task lifecycle Quint models, and host
PostgreSQL tests are complementary evidence, **not** a universal
implementation-refinement theorem. A checked proof of the guarded model
does not establish the actual PostgreSQL host correspondence. Prove the
formal model's safety under explicit fairness/crash assumptions, then
establish its correspondence to all supported runtime paths and actual
authorization snapshots. A SQL lease alone cannot close the gap between
a time-dependent grant change and external launch; the threat model must
define which current-state and revocation serialization properties are
guaranteed.

## Reproducibility

The existing `.github/workflows/agent-core-storage.yml` runs the
PostgreSQL/Elixir `AgentOpsStore` integration suite in a named-volume Docker
fixture on PRs changing `apps/agent_ops_store/**`. This PR relies on that
existing workflow; it adds no redundant pipeline or deployable service.

All status claims remain **not established** until exact-head CI completes.
No credentials, financial writes, plugin activation or production coordinator
are introduced.

## Formal checking integration

The repo-pinned Lean 4.35 pipeline builds `BizKitAgentTask`, freshly replays
its declarations in the Lean kernel, and includes it in the axiom audit.
A proof about the abstract post-claim guard is a separate evidence class
from the real integration tests; both must succeed at the **same exact head**.
No new trusted axiom, proof bypass, or production authority is introduced.
