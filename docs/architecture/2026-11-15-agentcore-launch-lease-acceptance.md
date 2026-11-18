# AgentCore launch-lease acceptance

The [durable admission increment](2026-11-16-agentcore-durable-launch-admission.md)
adds a separate opt-in decision ordered with canonical append and a signed
database-restart probe. It preserves the direct-dispatch boundary described
here; an admission receipt does not prove physical backend execution.

## Problem and integration scope

The review of PR #398 at `fefe7394ffacd6c49e9d22cf3224af731f039b3c`
and PR #165 at `051a7255f091ca49c907c3751cd837760115b7e1` found an
unintegrated repair. The dispatcher on main rechecked signed authority after
claiming, but then called its adapter without checking whether the lease had
expired or been cancelled during that wait. Rejecting the subsequent backend
attachment cannot undo a launch that already happened.

This increment is based on main
`e112bcfb68b8d22bbb7418cf9ab494bb71cd2f96`. It brings forward the small
lease validator from #165, the post-claim authority cases and abstract guard
model from #398, and a focused signed execution fixture adapted to current
TaskCore admission. It does not merge either entire historical branch.
In particular, #166 merged into #165's branch; its native subscriber and
checkpoint architecture are not integrated by this change.

## Implemented launch boundary

`TaskCore.Dispatcher` requires the trusted host's `validate_lease` callback
after the post-claim `prepare` returns the same plan. Only literal `:ok`
permits the adapter invocation. Missing, malformed or failing validation
leaves the claimed effect blocked; it does not return the effect to pending.

`AgentOpsStore.Coordinator` supplies `Postgres.validate_launch_lease/3`.
It checks the exact effect ID, row version, epoch, SHA-256 token digest,
`leased` phase, absence of an attached backend, lease expiry and execution
deadline using PostgreSQL's clock. Only connection processes or registered
pools are supported: a caller-owned transaction handle is refused. The host
must still use the committed autocommit claim API; this interface is not an
attestation of arbitrary raw SQL issued by a trusted host.

The operational database remains a projection. A lease neither authenticates
a signed run nor grants task access. The Coordinator still requires current
operator/suggester/read/execute authority, the original task version and
source, the approved profile digest, capabilities and consent. It remains
explicitly staging-only; this increment installs no production worker,
backend, public launch endpoint or business writer.

## Acceptance evidence classes

| Suite | Actual boundary | Limits |
| --- | --- | --- |
| TaskCore dispatcher | Actual dispatch algorithm; invalid/missing/failing validator controls; retained lease and no retry | Simulated ports, no SQL or signatures |
| AgentOpsStore PostgreSQL | Real registration/CAS; exact token/version/epoch; independently expired lease/deadline; second-connection cancellation; transaction-handle and unavailable-SQL refusal | Disposable database, no external backend |
| AgentOpsStore dispatch | Six post-claim mutations: operator, task version and profile digest, each against local and remote adapters; exact refusal and retained fence on redelivery | Process-local TaskCore state and registry; no signed admission |
| CoopSubstrate signed launch | Actual signed append/replay and canonical profile digest; native SQL; forged/duplicate/lost hints; signed operator/task changes; post-claim lease expiry/cancellation; Log and SQL-session restart | Test adapters, test observation issuer and host profile registry |
| Lean `BizKitAgentTask` | Abstract authorization observations and lease-validity guard; missing-recheck and missing-lease-check counterexamples | No Elixir/SQL correspondence, signatures, clocks, crash semantics or external effects |

The signed fixture gives the project a separately authorized human owner so
revoking the run operator exercises run authority rather than the ownership
invariant. Operator revocation and task version changes are genuine admitted
signed events. Profile mutation is a trusted host configuration change; the
run's old digest remains authenticated signed history. It is not a newly
admitted or newly approved profile.

After each of those three drift cases, the fixture checks the real signed
chains, restarts Log, replaces the SQL connection and repeatedly redelivers
the original run. The same attempt must remain `cancel_requested`, with one
attempt, no backend reference and zero adapter calls. No business events may
be appended by that redelivery.

The volume workflow separately saves the six actual drift-test cancellation
rows, requires their expected phase/attempt count/no-backend state, recreates
the PostgreSQL container without deleting its named volume, and compares the
same effect/descriptor/version/epoch records. This is stronger than the
previous generic volume marker alone. These rows are still from the simulated
authority fixture: it is not a signed-ledger VM or host-power-loss replay.

## Reproduction and regression control

Use the pinned Elixir 1.19 / OTP 27 environment and PostgreSQL 16. The
`AgentCore signed launch acceptance` workflow checks out and records the
literal PR head, stages the existing 15-app dependency closure with the full
repository lock, compiles with warnings as errors, checks changed source/test
formatting, and runs:

```sh
cd apps/coop_substrate
mix test test/agent_event_acceptance_test.exs test/task_agent_run_intents_test.exs \
  --warnings-as-errors --trace --seed 1
mix test test/agent_event_acceptance_test.exs test/task_agent_run_intents_test.exs \
  --warnings-as-errors --trace --seed 9173
```

Its workflow file contains the disposable database and stage setup. The
existing AgentCore volume workflow applies the checked-in SQL migrations,
runs `apps/agent_ops_store` with `--include integration --seed 1`, and checks
the actual cancelled rows after container recreation. The formal workflow
builds the new module, replays it freshly in the kernel and audits axioms.

For a negative regression control, replace only the Dispatcher in an isolated
test stage with the pre-repair main implementation. The invalid-lease unit
case and signed lease-expiry/second-connection-cancellation cases must fail
because the adapter is invoked. Restore the candidate implementation and
require the same assertions to pass. Do not change assertions to accept the
old behavior or substitute a validator-only unit test for native delivery.

Actual pass counts, source revisions, CI runs and any inherited failures must
be reported with the proposed PR. The existence of a test or workflow is not
acceptance evidence.

## Remaining ordering and durability limits

Neither the second authority read nor the lease validation is atomic with an
external adapter call. Authority can change after the last observation while
the operational row remains leased. Even a valid SQL check can be followed
by cancellation before a remote side effect. This change closes the observed
stale-lease interval during authorization; it does not claim that all later
revocations prevent launch.

A production contract must define the ordering of signed revocation, durable
launch admission and backend execution, with backend-enforced fencing or an
equivalent reviewed protocol. Current tool access and result admission must
also recheck authority. A cancellation request does not prove termination.

The signed test backend is an Elixir Agent that survives worker and Log
restarts. Its synthetic observation issuer is not a real receipt verifier.
Independent backend-process/host restart, durable backend deduplication,
authenticated finality, database power-loss/failover, production-host trust,
native subscriber/checkpoint integration and controlled rollout remain under
[issue #92](https://github.com/larsbx/biz-kit/issues/92).

See the [refinement obligations](../proof-bank/agent-task/REFINEMENT_V1.md),
[original staging boundary](2026-10-27-agentcore-staging-acceptance.md), and
[signed receipt replay boundary](2026-10-28-eventstore-signed-replay-acceptance.md).
