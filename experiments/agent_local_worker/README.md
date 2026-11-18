# Fixed local worker acceptance

This Linux staging provider starts one real, fixed, non-forking Python process.
The worker computes a bounded SHA256 sample and writes a 65-byte result, then
remains alive for at most 30 seconds or the earlier admitted
deadline. A fresh manager can recover the same live worker and terminate it
through a pidfd bound to its retained identity. There is no arbitrary-command
interface.

It is a narrow physical-execution experiment, not an agent sandbox, production
adapter, model invocation, or OpenShell/Hermes policy demonstration. The earlier
`../agent_backend_receiver` remains a request receiver that never executes work.
Its validation/private-file helpers are reused, but its database schema and
response contract are separate and unchanged.

## Run the acceptance

Prerequisites are Linux, Python 3.12, `pidfd_open`, `pidfd_send_signal`, and
readable `/proc`. There are no Python package installs.
Use the same trusted user and PID namespace for managers and workers.

From the repository root:

```sh
export AGENT_LAUNCH_SOURCE_REVISION="$(git rev-parse HEAD)"
export AGENT_LOCAL_WORKER_EVIDENCE_DIR="$(mktemp -d)"
python3 -m unittest discover -s experiments/agent_local_worker -p 'test_*.py' -v
```

Signed PostgreSQL integration lives in
`apps/coop_substrate/test/agent_local_worker_test.exs`. The
`AgentCore signed launch acceptance` workflow runs both Python experiments,
the full focused signed suite at seeds 1 and 9173, and the separate admission
PostgreSQL restart probe. It uploads source identity, logs and bounded evidence.

## Private stdio interface

Create an owner-only `0700` directory. Initialization creates a new
`0600` SQLite database and returns its random store ID:

```sh
python3 experiments/agent_local_worker/provider.py init --db /path/to/private/worker.sqlite3
python3 experiments/agent_local_worker/provider.py request --db /path/to/private/worker.sqlite3
```

`request` reads one bounded JSON object from stdin to EOF and writes one JSON
response. Every request uses `schema: "bizkit.agent-local-worker-request.v1"`,
pins `store_id: "agent-backend-store:<32 lowercase hex>"` and names an
`effect_id` using the reference receiver's `agent-run:` grammar.

| Operation | Additional fields | Meaning |
| --- | --- | --- |
| `create` | `admission_id`, `plan_digest`, `execution_deadline` | Bind one irreversible spawn reservation, then attempt the fixed worker once |
| `lookup` | None | Read retained identity and attempt live identity verification; unknown is not absence |
| `fence` | None | Commit permanent refusal of future creates; does not terminate a live worker |
| `terminate` | None | Commit the fence, verify the worker identity and open its pidfd, signal it, observe kernel exit, then retain that observation |

The admission ID is `agent-admission:` followed by SHA256 of the effect ID.
The plan digest is 64 lowercase hex digits. The deadline is a future UTC ISO8601
timestamp; its exact validated spelling remains bound. These fields are
trusted-host inputs, not proof of signed authority. The signed fixture derives
them from a real `Log.admit_agent_launch` receipt before invoking this provider.

Successful receipts use `bizkit.agent-local-worker-receipt.v1`; initialization
uses `bizkit.agent-local-worker-store.v1`; errors use
`bizkit.agent-local-worker-error.v1`. The original receiver's response validator
does not accept these as request-only receipts or verified recovery observations.

`execution_started` is `true` only after a committed real-work sample, `false`
for a never-reserved tombstone, and `null` for unknown or unacknowledged starts.
`worker_identity` records boot ID, PID and start ticks. `work_count` is zero or
one; `result_digest` records the fixed result. `ambiguity` names unresolved
observations. `termination_verified` requires a kernel exit observation on the verified pidfd;
missing PIDs do not establish it. A fixed work result has already been produced before a reply with
`execution_started: true` and is not undone by termination.

## Crash and fence semantics

The committed `starting` reservation is irreversible. Redelivery never spawns
for an existing reservation, even when the original manager died before its
one spawn attempt. A child that was actually spawned can register itself after
the manager dies, allowing fresh-process reconciliation. An unresolved start
remains blocked, sacrificing availability rather than risking duplicate work.

The provider orders spawn and work against its own durable SQLite fence. A
signed ledger change or operational SQL cancellation does not automatically
reach it. The host must deliver and obtain the provider's fence acknowledgement.
`terminate` is separate from `fence`, and observes the exact process handle
bound to the fixed worker; it never signals a recovered numeric PID. The manager
checks `/proc` ownership, boot ID/start ticks and the exact retained argv/launch
nonce before and after opening the descriptor, then verifies its kernel PID.
The fixed code never changes argv, forks or re-execs. A mismatched identity
remains unresolved. The store contains the internally constructed argv; no
request can supply an executable or argument list.

Missing/replaced state refuses the pinned store identity. Process-crash tests
are not power-loss, disk-failure, backup-rollback, host-reboot or remote-failover
tests. The implementation trusts the owning host, the private store and the
fixed worker code. It does not defend against a hostile process with the same
user credentials or terminate arbitrary descendant trees.

`barrier_provider.py` and the test suite contain bounded fault injection only.
No fault, release, arbitrary executable or test barrier operation exists in the
provider's production stdio request schema.

See the [full contract and next acceptance boundary](../../docs/architecture/2026-11-16-agentcore-fixed-local-worker.md)
for signed versus unsigned changes, evidence levels, exact commands and limits.
