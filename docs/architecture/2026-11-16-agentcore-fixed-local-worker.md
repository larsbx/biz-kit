# Fixed local worker: actual execution, lost replies and observed termination

Status: opt-in Linux staging experiment. This is an additional acceptance
boundary after [durable launch admission](2026-11-16-agentcore-durable-launch-admission.md)
and the [durable request receiver](2026-11-16-agentcore-durable-backend-receiver.md).
It does not register an `ExecutionPort` or `RecoveryPort` implementation, change
the legacy Coordinator, or grant production execution authority.

## The concrete gap

The reference receiver can retain one request identity across receiver crashes,
but it never creates a workload. Its durable row therefore cannot demonstrate
that one worker ran, that a lost creation reply will not launch another worker,
or that cancellation stopped a live process.

`experiments/agent_local_worker` crosses that boundary with one fixed Python
worker. The child computes a bounded SHA256 sample, records its result and
remains alive for at most 30 seconds
(or the earlier admitted deadline). It accepts no arbitrary command, model
prompt, executable, network endpoint, business input or credential. The worker
does not fork or execute descendants. The manager uses fresh OS processes and
an independent SQLite store for create, lookup, fence and terminate requests.

This is actual local process execution. It is not container isolation, a remote
provider, a model invocation, a sandbox policy test or a production adapter.

## Retained identity and the deliberate availability tradeoff

Every create binds the store ID, effect ID, effect-derived admission ID, complete
plan digest and exact execution-deadline spelling. The fixed workload revision
and internally constructed worker argv are immutable operational bindings.
No wire request can supply an executable or command arguments. A new store receives a new
random ID. Every operation pins that ID; a missing store is never recreated by
request handling, and a replacement store refuses requests pinned to the old ID.

The provider first commits an irreversible `starting` reservation. Only the
call that inserted that reservation may attempt the one spawn. A concurrent
or restarted manager returns the retained state and never spawns a replacement
for an existing reservation. This includes a manager that crashes before it
has spawned anything. The record intentionally remains unresolved: availability
is sacrificed because the store alone cannot distinguish that case from an
unobserved successful spawn.

The original creator then takes the provider's SQLite write lock again,
rechecks the permanent fence and deadline, and starts the fixed child while
holding that lock. A fence that wins this ordering prevents the spawn; a fence
that follows it cannot honestly claim that no process was started. The child
registers itself against the retained nonce and binding before performing any
fixed work. Its registration and work checks also honor the provider fence.

`execution_started: true` requires a committed work sample, not merely a
successful `Popen` or a row called `running`. A reserved but unobserved start
remains `null`/ambiguous. A never-reserved fence can report `false`. Unknown
lookup is not proof of final absence.

A fixed work result has already been produced before a reply with
`execution_started: true`.
Terminating the remaining process does not undo that result. The experiment
does not permit the worker to perform business effects.

## Recovering the same live process

A PID is an observation, not a reusable process handle. The worker records its
boot ID, PID and `/proc` start ticks. The store also retains the exact internally
constructed worker argv, including a unique per-launch nonce. The manager
verifies `/proc` ownership, boot/start identity and the complete argv before and
after `pidfd_open`, and verifies the descriptor's own PID and kernel signal-0
operation. Only then may it signal the pinned descriptor.

The identity record exists before this lookup. With the fixed trusted worker,
no fork/re-exec, and no second spawn for a retained reservation, another process
cannot legitimately receive that same launch nonce and argv. A benign recycled
PID therefore fails the binding checks. Once accepted, the pidfd continues to
identify the original process regardless of later PID reuse. A missing or
mismatched identity remains unresolved; there is no numeric-PID signal fallback.
This is the trust argument tested here, not a defense against a hostile process
with the same user credentials or access to the private store.

The provider requires the same trusted local user, host and PID namespace, with
readable `/proc`. It uses no listening socket, broker or remote authentication
protocol. An early design using a Unix socket and `SCM_RIGHTS` was rejected from
this increment after the execution environment refused named Unix socket
creation with `EPERM`. The current design is explicit and uniform; it does not
silently switch recovery protocols at runtime. The failed socket-dependent run
is retained as an environment diagnostic, not successful execution evidence.

A dead process, missing `/proc` entry, changed boot ID or mismatched argv is not
promoted to verified termination. If the worker exits before a fresh manager
can verify the identity and retain its pidfd, the record may remain unresolved. A
manager that dies after observing exit but before committing that observation
can likewise lose the ability to prove termination; a later manager must not
invent the lost observation.

The kernel makes a pidfd readable when its process exits, and reports a hangup
after reaping. Only an exit observation on the verified descriptor allows
the manager to commit `termination_verified: true`. The committed receipt can
then be read by another fresh manager. `waitpid`/`waitid` are not used as a
universal recovery proof because a restarted manager is not the original
worker's parent.

Sources for these kernel primitives:

- [Python 3.12 `os.pidfd_open`](https://docs.python.org/3.12/library/os.html#os.pidfd_open)
- [Python 3.12 `signal.pidfd_send_signal`](https://docs.python.org/3.12/library/signal.html#signal.pidfd_send_signal)
- [Linux `pidfd_open(2)` polling and child-wait semantics](https://man7.org/linux/man-pages/man2/pidfd_open.2.html)

The guarantee covers this one fixed, non-forking worker. A general workload
would require a process-tree or sandbox identity and a termination contract
that covers descendants and external effects.

## Fence acknowledgement and signed authority remain separate

`fence` permanently refuses later creates. It does not itself terminate a
running worker and does not set `termination_verified`. `terminate` first
commits that same permanent fence, then attempts bound pidfd recovery
and kernel-observed termination. An unresolved termination retains the fence.

The signed integration tests execute the host sequence explicitly:

1. Obtain a genuine signed intent and `Log.admit_agent_launch` receipt.
2. Append a signed operator revocation or task-version change, or supply a
   changed host profile and observe its digest rejection.
3. Read back the operational SQL cancellation.
4. Obtain the separate provider's committed fence acknowledgement.
5. Release a delayed create, or terminate the already-running fixed worker.
6. Reconcile through another fresh manager process and compare the full binding.

The profile change is explicitly **unsigned supplied host policy**: its case
asserts that the canonical signed source head did not change. Operator and task
changes are real signed append/replay events. The provider consumes a trusted
host request; it does not independently verify that signed authority.

There is no transaction joining signed PostgreSQL authority, operational SQL
cancellation and this SQLite provider. A committed withdrawal alone does not
reach the worker automatically. The launch refusal guarantee starts at the
provider's own acknowledged fence. This increment neither installs a durable
withdrawal delivery loop nor closes the legacy final-check-to-adapter-call race.

## Evidence levels

| Boundary | What can be demonstrated | What it does not establish |
| --- | --- | --- |
| Process-local authority tests | Local simulation and operational SQL transitions | Signed canonical origin or physical work |
| Signed admission | Genuine signed append/replay, exact plan binding and SQL commit ordering | Physical execution |
| Reference receiver | SQLite request identity, permanent fence and lost-reply recovery | Any worker start or termination |
| Fixed local worker | Actual child work, same worker after a manager crash, no automatic ambiguous respawn, bound pidfd termination | General sandbox/provider safety or automatic cross-store withdrawal delivery |
| PostgreSQL restart probe | Same signed source/admission/cancellation after PostgreSQL restart and a fresh BEAM VM | SQLite power-loss recovery, host reboot, backup rollback or provider failover |

SQLite `synchronous=FULL` and successful commits specify the intended persistence
boundary. Actual tests kill manager processes and reopen retained storage; they
do not simulate loss of host power, storage corruption or rollback to an older
backup with the same store ID. Those failures must not be inferred from passing
process-restart tests.

## Reproducible acceptance

From a clean exact source revision on Linux with Python 3.12 and pidfd support:

```sh
git rev-parse HEAD
export AGENT_LAUNCH_SOURCE_REVISION="$(git rev-parse HEAD)"
export AGENT_LOCAL_WORKER_EVIDENCE_DIR="$(mktemp -d)"
python3 -m unittest discover -s experiments/agent_local_worker -p 'test_*.py' -v
```

The independent Python cases exercise reservation and spawn crash windows,
concurrent redelivery, permanent fences, real fixed work, bound live
recovery, missing or replaced storage, and termination without numeric-PID
signaling. Fault barriers live only in `barrier_provider.py`; the production
stdio protocol has no test control or arbitrary-command fields.

The `AgentCore signed launch acceptance` workflow checks out the actual PR head
or pushed revision, stages the same locked dependency closure as the earlier
admission/receiver work, runs both Python suites and then runs:

```sh
cd apps/coop_substrate
for seed in 1 9173; do
  mix test test/agent_event_acceptance_test.exs test/task_agent_run_intents_test.exs \
    test/agent_launch_admission_test.exs test/agent_backend_request_test.exs \
    test/agent_backend_receiver_test.exs test/agent_local_worker_test.exs \
    --warnings-as-errors --trace --seed "$seed"
done
```

The seven new signed cases cover the three changes before create, the same
three after actual work, and manager SIGKILL after real work but before the
ordinary creation reply. A separate observer retains a pidfd before termination
and verifies its kernel exit notification independently of the provider's JSON
receipt. Evidence records include the source revision, signed source identity,
admission/plan binding, manager and worker identities, zero creation-reply bytes
in the crash case, fixed-work result, permanent fence and termination observation.
No signing seeds, lease tokens, credentials or arbitrary plan contents are
included.

The workflow then repeats the separate PostgreSQL restart/fresh-VM admission
probe and uploads logs and bounded JSON receipts. Workflow configuration is
not a successful run. Report native execution, actual hosted job steps, exact
checkout SHA, artifact metadata and any queued or failed lane separately.

## Next acceptance boundary

The next useful check must choose a real execution backend with a stable
effect-bound identity. Withhold its create response after actual workload
start, restart the host, redeliver the same effect and prove one execution.
Then replay each authority change through a durable host delivery mechanism,
acknowledge the backend fence, and prove the complete workload cannot continue
or be recreated. Retain the backend's independent identity and termination
evidence through its own restart or failover.

For OpenShell or another sandbox, that check must also exercise the actual
network, filesystem, credential and resource policies and descendants. This
fixed child cannot substitute for those observations. Do not translate its
receipts into general `RecoveryPort` `verified: true` values, enable a production
adapter, or promote an implementation-refinement proof badge from this work.
