# AgentCore durable launch admission

## Scope and predecessor

PR #420 added the post-replay lease check to `Coordinator.deliver/4` and
demonstrated signed replay with synthetic execution adapters. Its final
Quint safety and coverage retries passed at
`815b92d5643dab8b56056bfebff712db3527c339`. The merge
`be306bab645ea70e0b4405eed1662d02456654ca` independently passed signed launch
acceptance and formal safety. Its Location browser run passed on the same
tree and client pin as the earlier timing failure. These historical results
do not establish acceptance for later source revisions.

This increment starts from main
`d1ab39a99f96ba96978918653f0a36bac9976bcc`. It adds an explicit, opt-in
**durable admission decision**. A launch receipt records that decision;
it does not mean an execution backend was created or started.

The existing `Coordinator.deliver/4` and `ExecutionPort.launch/3` interfaces
retain their earlier behavior. They do not automatically use this new API.
Their final-check-to-external-call race remains. No production worker,
endpoint, external backend, or business writer is enabled by this change.

## Public staging entry point

```elixir
CoopSubstrate.Log.admit_agent_launch(
  %{environment: :staging},
  %{
    run_key: {chapter, tenant, project, run},
    grants: %{read: read_grant_id, execute: execute_grant_id},
    registry: trusted_registry,
    requirements: trusted_requirements,
    plan: expected_preflight_plan,
    lease: %{version: claim_version, epoch: epoch, token: host_only_token}
  }
)
```

Only a trusted host may call this API. Context and request shapes are closed;
caller database connections, schemas, transaction handles and callbacks are
refused. The transaction uses the **running canonical EventStore pool and
its cached schema**, obtained from `EventStore.Config.lookup/1`. It does not
reparse mutable application settings to select a different database.

The host must obtain consent and supply its current approved profile and
requirements snapshot. Those policies are not signed or serialized by this
API. An `environment: :staging` marker is a host integration restriction,
not authentication for an untrusted client.

## Transaction and ordering

The Log handler supplies its own recovered gate and head. In one bounded
PostgreSQL transaction, admission:

1. Locks the actual undeleted EventStore `ledger` stream row. This is the row
   canonical append updates, including appenders in other processes.
2. Requires its sequence and SHA-256 of the stored full head record to equal
   the Log's verified cached head. A stale appender refuses; it does not use
   a cached grant merely because its process still exists.
3. Rechecks `TaskCore.AgentRuns.authorized?/3`, reconstructs the preflight
   with the canonical manifest hash, checks the recovery contract and
   compares the complete expected plan.
4. Locks the operational attempt, then checks its exact descriptor, epoch,
   token digest, version, leased phase, absent backend, lease expiry and
   execution deadline using database time after lock acquisition.
5. Inserts one immutable admission receipt, advances the attempt version,
   commits, and only then returns the receipt.

Lock order is always **ledger, then attempt**. There is no remote call or
adapter invocation under either lock. Lock, statement and transaction waits
are bounded. An error or ambiguous call result never resets the attempt to
pending or permits a second effect identity.

The commit orders admission against canonical append:

| Ordering | Result |
| --- | --- |
| Signed operator revocation or task-version change commits first | Fresh authorization or the stored-head fence refuses admission; no receipt is inserted. |
| Admission takes the ledger lock first | A competing canonical append waits. Admission commits its original source receipt before the later event can commit. |
| Operational cancellation wins the attempt row first | The claim is no longer live and admission refuses. |
| Cancellation occurs after admission | The immutable receipt remains historical evidence; the operational attempt is fenced separately. A request for cancellation is not proof of termination. |
| Lease/deadline expires while admission waits | The time check after attempt-lock acquisition refuses the receipt. |

Advancing the attempt version invalidates subsequent SQL operations using
the original claim. It cannot recall a legacy adapter call already past
its last validation. Likewise, an admission committed before a later
revocation is not a promise that physical execution may proceed afterward.

## Exact plan and receipt integrity

The existing operational descriptor checksum is preserved byte for byte.
It binds the stable signed run identifiers, task source/version, profile
digest and budgets, using the pre-existing BEAM encoding. It is not a
canonical signature and does not include all host requirements.

Admission separately records `plan_digest`, SHA-256 of the closed canonical
`bizkit.agent-launch-admission-plan.v1` payload. It includes the entire known
preflight plan, execution ticket, profile manifest and requirements, with
module identities represented as strings. Unknown plan/profile/execution
fields are refused rather than omitted. A different valid requirements
snapshot cannot replay a previous receipt just because the old operational
descriptor happens to match.

Only digests and operational identifiers are persisted. The API does not
copy full manifests, prompts, signing keys, plaintext lease tokens or
credentials into the receipt table. Reconstructing `plan_digest` requires
the retained approved manifest and policy snapshot; the digest alone is
not an independently authenticated record of host approval.

`agent_ops.launch_admissions` retains the effect-derived admission ID,
original claim and admitted versions, epoch, both digests, source sequence
and hash, read/execute grant locators, admission time and execution deadline.
`admitted_at` is the database time observed for the SQL decision, not a
measured COMMIT timestamp; ordering comes from the held locks and transaction.
Ordinary UPDATE and DELETE are refused. The SQL function's PUBLIC execution
privilege is revoked; it cannot validate the signed-source precondition by
itself and must not be exposed directly to agents or clients.

An identical request can recover the same receipt while the original claim
remains live and unchanged at the admitted version. Cancellation, renewal,
expiry, another epoch, or a changed bound plan refuses that entry point.
The receipt itself persists for historical reconciliation after those
changes. There is no time-based retry or new backend allocation.

## Native acceptance and restart probe

`agent_launch_admission_test.exs` exercises real signed append and native
PostgreSQL. The two ordering tests use independent Log appenders and actual
SQL blocking relationships, rather than a single GenServer mailbox or
elapsed sleeps. Other cases cover stale sequence/hash, current authority,
changed host profile digest, live-claim fields, closed inputs, immutable
records, configuration substitution and complete-plan replay conflicts.
The fixture's execution adapter raises if invoked: these are admission tests.

The exact-head signed workflow runs those cases together with the #420
signed launch and existing run-intent suites at seeds 1 and 9173:

```sh
cd apps/coop_substrate
mix test test/agent_event_acceptance_test.exs \
  test/task_agent_run_intents_test.exs test/agent_launch_admission_test.exs \
  --warnings-as-errors --trace --seed 1
# Repeat with --seed 9173.
```

The same workflow then executes
`scripts/agent_launch_admission_probe.exs` in two separate BEAM processes.
The first commits an actual signed run, admission, signed operator revocation
and operational cancellation. It writes a non-secret expected receipt.
PostgreSQL is restarted preserving its data. A fresh process starts Log from
the stored history, verifies the signed chains and exact original admission
source, and compares the admission and cancelled attempt byte for byte.
It requires a changed database postmaster start time and a different VM PID;
merely opening another connection does not satisfy this probe.

```sh
export MIX_ENV=test
export AGENT_LAUNCH_SOURCE_REVISION="$(git rev-parse HEAD)"
cd apps/coop_substrate
mix run --no-start ../../scripts/agent_launch_admission_probe.exs prepare /tmp/agent-admission.json
# Restart only the dedicated disposable PostgreSQL test instance here.
mix run --no-start ../../scripts/agent_launch_admission_probe.exs verify /tmp/agent-admission.json
```

The runner requires the disposable `coop_substrate_eventstore_test` database
before destructive fixture setup. This demonstrates retained signed source,
admission and cancellation through the specified process/database restart.
It does not test VM power loss, storage corruption, failover or a real backend.
Exact revisions, test counts and execution receipts belong in the PR/CI
evidence; a checked-in runner is not a completed acceptance result.

Meaningful negative controls are an omitted stored sequence/hash fence,
which admits a stale appender, and replacing the complete plan digest with
the old descriptor checksum, which accepts changed valid requirements.
Both controls must fail the corresponding behavioral assertions. A compile
error or unavailable database is not a successful negative control.

## Remaining backend boundary

The [durable reference receiver increment](2026-11-16-agentcore-durable-backend-receiver.md)
adds an independent operational request store, reply-loss recovery and
permanent fences. It has no workload execution and does not make signed
withdrawal atomic with a separate receiver or a physical backend.

Host approval and consent changes after the supplied snapshot are not
serialized here. Physical start, cancellation delivery, durable backend
deduplication and authenticated termination remain under issue #92. The
existing `BizKitAgentTask` Lean model proves its older abstract observation
guards; this new transaction does not acquire a Lean/Elixir/SQL refinement
proof from that model.

The next backend acceptance needs a reviewed consumer of this immutable
admission identity and exact plan digest. Hold its create request before
backend acceptance, commit signed withdrawal and the operational fence,
then release the old request and require refusal. Kill the independent
backend after durable acceptance but before its reply, restart it, and
require one retained identity and no second execution on redelivery.
The backend must also preserve cancellation tombstones and prove finality;
a receipt ID or a successful cancellation request does not establish either.
