# AgentCore durable reference backend receiver

## Scope and predecessor

PR #424 merged at `75a3c271001ae6d97f51c3bcfa02eca88ab24adc`. Its
[admission contract](2026-11-16-agentcore-durable-launch-admission.md) orders
a PostgreSQL admission receipt against the canonical signed source and live
operational attempt. It does not create an execution backend.

This increment adds an **independent staging reference receiver** with its
own durable request identity and permanent cancellation tombstones. It
exercises real OS processes and SQLite commits. It does not execute a
workload, provision a sandbox, call a model or implement a production
`ExecutionPort` adapter. One retained receiver record is evidence of one
request identity; it is not evidence of one physical execution.

The legacy `Coordinator.deliver/4` path is unchanged. Neither this receiver
nor its test transport is installed in a supervisor or exposed as a network
endpoint. OpenShell, Hermes, Pi, current business-tool authority, candidate
custody and production rollout remain under issue #92.

## Host and receiver boundary

`CoopSubstrate.AgentBackendRequest` constructs closed requests from a trusted
plan, the actual `Log.admit_agent_launch/3` receipt and a configured receiver
store identity. It recomputes both the operational descriptor checksum and
the complete canonical plan digest. The effect, admission ID, source fields,
claim versions and time fields must have the expected shape and binding.

This is a structural binding function. It does not authenticate its caller,
replay signed history, look up the admission in PostgreSQL or establish that
a host-supplied receipt is genuine. The trusted host must obtain the receipt
from the signed Log entry point and retain its approved policy snapshot.
The receiver receives no signing keys, lease tokens, business credentials,
full manifest, private task evidence or arbitrary executable.

The reference transport invokes a known Python file as a separate OS process
and exchanges one bounded JSON document over private stdio. The local owner
and configured executable/storage paths are trusted. There is no network
authentication or portable signed-provider receipt in this protocol.

The response verifier checks structure and request bindings. It never turns
a reference observation into `verified: true` for `ExecutionRecovery`, a
business fact, current task authority or evidence of physical termination.
A lookup request names only the store and effect. Recovery must additionally
compare the returned admission, plan digest and deadline with the retained
original create binding; structural validation of a lookup does not supply
those expected values independently.

## Closed protocol

All operation requests use schema `bizkit.agent-backend-request.v1` and the
configured `store_id`.

| Operation | Additional request fields | Durable meaning |
| --- | --- | --- |
| `create` | `effect_id`, `admission_id`, `plan_digest`, `execution_deadline` | Retain one immutable receiver identity for that exact binding while the deadline is live. |
| `lookup` | `effect_id` | Read the retained identity/fence, or report non-final `unknown`. |
| `fence` | `effect_id` | Commit a permanent tombstone even if no create has arrived. |

The effect is the existing `agent-run:` identity derived from signed run
intent. The admission ID must equal `agent-admission:` followed by SHA-256
of the effect's UTF-8 bytes. The complete plan digest and deadline are bound
to the original admission. A changed valid binding is a conflict, never an
update to an accepted request.

Responses use `bizkit.agent-backend-receipt.v1`, echo the operation, store
and effect, and retain the immutable binding where it exists. The reference
receiver always reports `execution_started: false` and
`termination_verified: false`.

| Observation | What it establishes | What it does not establish |
| --- | --- | --- |
| `accepted` | An immutable request identity committed in this receiver store. | A workload exists, started or completed. |
| `unknown` | This store currently has no record for the effect. | Final absence; an older create may still arrive. |
| `fenced` with `future_creates_refused: true` | The retained tombstone refuses later creates for the effect. | Termination of work accepted by another implementation. |

Fencing an accepted effect preserves its original identity and binding.
Fencing an unknown effect retains a tombstone with no invented backend ID.
Repeating either operation does not erase or replace the fence. New work
requires a new signed run-intent effect rather than reuse of the old effect.

## Durable storage and explicit initialization

The receiver is deliberately separate from biz-kit's canonical business
ledger. Its SQLite file contains only operational identities, request
bindings and fences. It uses bounded database waits and transactions with
`synchronous=FULL`. Success is emitted after the transaction commits.
Database constraints and mutation guards preserve immutable bindings and
prevent ordinary removal or reversal of a fence.

Initialization and serving are separate:

```sh
mkdir -m 700 /tmp/bizkit-agent-receiver-demo
python3 experiments/agent_backend_receiver/receiver.py init \
  --db /tmp/bizkit-agent-receiver-demo/receiver.sqlite3
```

Initialization creates a fresh `agent-backend-store:` identity. The trusted
host pins the returned ID. Every subsequent operation names it and uses the
existing file; request handling must not create a missing database. The
directory and state file must be owned by the current user with private
permissions. Symlink state paths are refused.

```sh
# REQUEST.json is produced by the trusted host, with the pinned store ID.
python3 experiments/agent_backend_receiver/receiver.py request \
  --db /tmp/bizkit-agent-receiver-demo/receiver.sqlite3 < REQUEST.json
```

A missing file refuses. A newly initialized replacement has a different
store ID and refuses requests pinned to the original store. These checks
do not detect restoration of an older copy bearing the same store ID;
anti-rollback storage and independently anchored checkpoints remain outside
this increment. The file's owner remains trusted and can replace software
or storage. No filesystem permission is represented as a business grant.

## Cancellation ordering across stores

PostgreSQL and the reference SQLite receiver do not share a transaction.
The tested guarantee begins at the **receiver's committed fence
acknowledgement**, not at the earlier signed withdrawal alone.

The signed acceptance follows this sequence:

1. Commit a genuine signed run and obtain its PostgreSQL admission receipt.
2. Construct the exact bound create request and hold it before receiver
   acceptance.
3. Commit a signed authority change, or observe a changed trusted host
   profile, and fence the operational PostgreSQL attempt.
4. Send the receiver fence and wait for its post-commit acknowledgement.
5. Release the delayed create and require refusal.
6. Reopen the receiver in a fresh process and require the same fence and
   refusal.

A supplied profile change remains host policy evidence; it is not relabeled
as a signed ledger event. An outstanding create can win before the receiver
fence arrives. This protocol does not close that propagation interval, make
physical spawn atomic with signed revocation, or recall a legacy call already
past its final check. A host must continue retrying/reconciling an uncertain
fence acknowledgement; an unacknowledged request is not a demonstrated fence.

## Reproducible acceptance

The standard-library receiver suite runs without a provider account or
external database:

```sh
python3 -m unittest discover -s experiments/agent_backend_receiver \
  -p 'test_*.py' -v
```

It exercises independent processes, concurrent duplicate requests, binding
conflicts, deadlines, pre-create and post-create fences, explicit store
initialization and missing/replaced-store refusal. The crash case pauses a
test wrapper after the real transaction commits and before it emits the
normal response. A separate reader observes the commit; the process is
killed with SIGKILL. A fresh process must recover the same identity and
matching redelivery must not insert another request record. Fault barriers
belong to test fixtures, not the receiver's public protocol.

The signed PostgreSQL integration is run with the existing suites:

```sh
cd apps/coop_substrate
mix test test/agent_event_acceptance_test.exs \
  test/task_agent_run_intents_test.exs test/agent_launch_admission_test.exs \
  test/agent_backend_request_test.exs test/agent_backend_receiver_test.exs \
  --warnings-as-errors --trace --seed 1
# Repeat with --seed 9173.
```

The exact-head workflow stages the Python receiver with the Elixir dependency
closure. It retains the actual source revision, Python/SQLite receiver log,
both signed-suite logs and any non-secret process/receipt evidence. It also
retains #424's separate-VM/PostgreSQL restart probe. Test definitions and a
configured workflow are not completed acceptance results; exact revisions,
counts and observed failures belong in the PR and run artifacts.

## Next provider obligation

A real provider must implement equivalent durable effect binding, lookup
and permanent cancellation fencing without treating this reference ID as a
bearer launch permission. Its acceptance must exercise actual workload
creation, crash after creation before reply, immutable backend identity,
orphan reconciliation and independently authenticated final termination.

In particular, persisting `starting` before spawning a worker does not prove
whether a process was created before a crash. An ambiguous attempt must not
be blindly restarted. A PID or one SQLite row is insufficient proof of one
physical execution. Pinned provider policy, protected credentials, current
per-tool business authority, two distinct real engines, and production
rollout gates remain separate.

The existing Lean guard model is unchanged. These executable cross-process
cases do not constitute a universal Elixir/Python/SQLite refinement proof,
power-loss test, failover test or production execution acceptance.
