# Queued and ready on the common ledger

The isolated common-ledger lifecycle now covers inbox → proposed → queued →
ready. Production SpruceGoose remains the writer for live tasks. There is no
execution/completion command, Buzz transport, second event store, importer or
writer switch in this change.

## Existing rules and the bounded replacement

SpruceGoose `Task` authorizes transition/move/acknowledge-SOP actions with the
operator role and optimistic row locks. `Lifecycle` v1 allows proposed → queued
and queued → ready. Artifact readiness requires verified receipts for every
named requirement. Predecessor completion is checked on entry to in-progress,
not ready. `SopGate` records the Systemwide SOP digest/version and checks the
current configured document before execution, with its documented patch-version
compatibility rule. Neither an accepted DoD review nor an approver role alone
licenses execution.

The isolated ledger path deliberately checks predecessors and SOP availability
earlier, before ready. It uses an exact, governance-declared SOP digest per task;
it does **not** claim to migrate deployed SOP adoption, grandfathered versions or
patch-version compatibility. Those remain production migration obligations.
Governance must commit the reviewed current Systemwide SOP digest in the task's
readiness definition. The command cannot supply a caller's approved/current flag.

| Command | Admission | Pure projection |
| --- | --- | --- |
| `TaskReadinessDefinedV1` | Declared chapter governance key, exact task version, proposed/queued task; ≤32 unique same-project predecessor IDs naming existing tasks, excluding self; ≤32 named SHA-256 input requirements; SOP digest. | Replace prerequisites, clear acknowledgment, increment version. |
| `TaskSOPAcknowledgedV1` | Active scoped operator grant/signature, lifecycle v1, exact version, proposed/queued task; committed same-project custody receipt matching the defined SOP and available bytes. | Record personal acknowledgment, increment version. |
| `TaskQueuedV1` | Active scoped operator grant, v1, exact version, proposed; prerequisites defined and personal SOP acknowledgment matching principal/key; SOP bytes available. | Queued, increment version. |
| `TaskReadyV1` | Same authority/version contract, queued; personal SOP acknowledgment remains valid/available, every committed predecessor is completed, exact receipt map matches the declared input digests and project scope; actual bytes verify. | Ready, preserve receipt references, increment version. |

Use signed `Envelope.new/1` + `Envelope.sign/3` commands through `Log.append/2`.
The existing gate validates types, signature cardinality, safe scope segments,
roles and grant revocations before these checks. Governance controls prerequisite
replacement; operators cannot erase predecessor or evidence requirements in a
transition. A replacement invalidates the acknowledgment and optimistic version.
Prerequisites cannot change once ready in this bounded path.

Input reads are bounded to 8 MiB each and 16 MiB total per readiness command;
SOP verification separately has an 8 MiB limit. Availability is true at admission,
not promised permanently. Future execution must recheck prerequisites and current
authority. Custody and review are facts, not grants. DoD remains separate and does
not determine readiness. Existing DoD commands remain proposed-only.

All facts use the existing signed PostgreSQL ledger. The projection folds only
accepted events, with no I/O on replay. The append gate uses committed state and
earlier events in the same atomic batch. Identical single-command retries return
the original accepted envelope after restart/revocation; conflicting IDs reject.
Store failure or batch rejection advances neither projection nor chain head.

## Definition of Done before queuing

Added 2026-10-18. `TaskQueuedV1` requires the task to have a Definition of Done
(`TaskDoDDefinedV1`), checked right after the state transition and before the
readiness prerequisites. A task without one is refused with `:dod_not_defined`.

Why: every DoD command (defining criteria, submitting evidence, reviewing) is
admitted only while a task is `proposed`. Without this check a task could move
to `queued` with no DoD and then never get one, leaving completion nothing to
be checked against. Requiring it at the last state where it can still be
defined closes that gap with one local check. `TaskReadyV1` needs no separate
check: a task can only be ready after being queued.

Governance signs the DoD and the readiness definition for the same task, so the
rule adds no new kind of step. Baselined tasks need a DoD before queuing like
any other. Tasks queued before this rule are not re-checked; on this rehearsal
path no production data exists. The rule is modelled in
[`spec/task_readiness.qnt`](../../apps/coop_substrate/spec/task_readiness.qnt).

## Remaining boundaries

A task with incomplete predecessors cannot become ready. No completed baseline
or caller-provided completion assertion is accepted. The common-ledger
completion path now exists ([execution](2026-10-19-execution.md)): a task is
started, its evidence reviewed, and an operator completes it citing the
accepting review; only then can a successor become ready. No task
hierarchy/definition importer or dependency-cycle scheduling engine is introduced.
This is an isolated rehearsal slice, not production command-coverage parity.

Before production cutover, migrate authoritative definitions, dependency edges,
SOP adoption/version rules and principals; implement execution/completion and
revalidation, prove parity/rebuild and recovery, fence the old writer, and record
cutover evidence as specified by the single-source architecture. Do not point
production callers at this path before those conditions hold.

`task_readiness_commands_test.exs` exercises real ledger admission, retries,
recovery, atomic rejection, stale versions, revoked/incorrect authority, missing
prerequisites, requirement replacement, unavailable/replaced bytes, wrong digests,
predecessor refusal and replay. The DoD command suite verifies an accepted review
still cannot queue a task without independent readiness prerequisites. The
Consolidation workflow compiles and validates the umbrella/common ledger and
SpruceGoose against disposable PostgreSQL 16.
