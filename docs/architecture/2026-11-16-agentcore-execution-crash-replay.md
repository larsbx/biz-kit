# AgentCore execution crash replay

The signed Log commits one immutable admission for a live claim and an exact
plan. The [durable reference receiver](2026-11-16-agentcore-durable-backend-receiver.md)
retains one request identity and a cancellation fence. This acceptance tier
connects those boundaries to a fixed Linux workload on a disposable host.
It runs explicitly through ExUnit. The Coordinator's legacy delivery path
does not select this fixture.

## Execution contract

The trusted host retains the genuine Log admission and the approved plan. The
backend receives the existing closed request containing the pinned store,
effect, admission, complete plan digest, and execution deadline. The fixture
manifest also pins the compiled workload's SHA-256.

| Operation | Requirement |
| --- | --- |
| Create | Recheck the committed source and live claim at the allocation boundary. Reserve the full immutable binding before issuing one start. Use the same backend identity on matching redelivery. |
| Lookup | Match a retained identity to the original admission, plan digest, deadline and any already observed backend ID. An unknown outcome stays held. |
| Fence | Durably block future creates for the effect, including an effect with no reservation. Request termination of the original workload by its immutable backend ID. Retry after a lost acknowledgement. |
| Observe termination | Require fresh evidence for the exact workload. A fence acknowledgement alone cannot confirm termination. |

Only the first committed receiver reservation can issue a native start. The
same stable identity names the worker's inherited liveness lock and stop
channel. A worker publishes its start witness after installing a Linux syscall
filter and checking the start deadline. It inherits two fixture descriptors
and no environment. It never receives task data, a lease token or business
credentials. The filter allows its descriptor I/O, time check and exit. The
worker also checks that the kernel refuses socket creation.

A fresh receiver uses the original binding and the kernel lock to observe the
workload after a lost reply. A reservation without a start witness is
ambiguous. The fixture holds that identity and cannot run another start from
it. Cancellation keeps the original binding; a separate process verifies the
worker consumed its stop byte and released the lock. The v1 reference receipt
itself still carries no verified execution or termination. These native
observations are local fixture evidence and do not enter production recovery.

## Signed authority at start

The fixture accepts the create payload on private stdio and waits for a
separate start permit. The trusted test host replays the exact durable
admission. It then checks the actual canonical PostgreSQL stream sequence and
stored head-record hash under the ledger row lock, and locks the matching
attempt. It uses database time after both locks and sends a permit bounded by
the live claim expiry and execution deadline. The live test session holds
both locks through the synchronous start witness or injected receiver crash.
The fixture checks the permit after its own lock wait as well, and the
restricted worker checks it immediately before writing its witness.

Two barriers make the ordering testable. One holds the create before current
signed replay. The other commits revocation after replay and before the host
obtains the canonical locks. Both require zero native starts and zero receiver
reservations without a propagated receiver fence. A separate case confirms
that the receiver's own fence refuses a held create. A live-workload test
uses `Coordinator.withdraw/3`, loses the fence acknowledgement before
delivery of the stop byte, then retries and independently observes the worker
stop. Current signed authority refuses candidate submission after withdrawal.

External runners still need provider-side idempotency and an execution fence
ordered with signed authority. In particular, this test's PostgreSQL session
and fixed synchronous driver are scoped to the local fault model. Loss of
that database session after issuing a permit, a remote provider acting after
disconnect, authenticated provider termination, state rollback, power loss and
OpenShell/Hermes/Pi parity require separate acceptance under issue #92.

## Run the acceptance

With the [signed launch workflow's](../../.github/workflows/agent-core-signed-ledger.yml)
isolated dependency closure and a disposable PostgreSQL test database:

```sh
cd apps/coop_substrate
mix test test/agent_event_acceptance_test.exs test/task_agent_run_intents_test.exs \
  test/agent_launch_admission_test.exs test/agent_backend_request_test.exs \
  test/agent_backend_receiver_test.exs acceptance/agent_backend_execution_test.exs \
  --warnings-as-errors --trace --seed 1
# Repeat with --seed 9173.
```

The explicit acceptance file requires Linux x86-64 or arm64, Python 3.11 or
later, a C compiler, and kernel support for unprivileged seccomp filters.
The tests use synthetic signed identities, private temporary stores, fixed
short-lived workloads and no provider account. The workflow also retains the
separate PostgreSQL/fresh-VM restart probe for admission and cancellation. The
execution case restarts the receiver and Log process while PostgreSQL remains
up. The two restart checks establish distinct boundaries.
