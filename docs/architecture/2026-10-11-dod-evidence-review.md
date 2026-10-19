# DoD evidence and independent review on the common ledger

This extends the [Buzz proposal/card stage](2026-10-11-buzz-task-workspace.md).
It is an isolated common-ledger rehearsal, not a production writer cutover.
Native signed commands are admitted by the existing serialized append gate.
There is no second business ledger, direct task-row write or network delivery.

## Contracts

| Event | Authority and precondition | Committed result |
| --- | --- | --- |
| `TaskReviewerGrantedV1` | Explicitly declared governance key; tenant/project, principal and reviewer key. | A reviewer-only scoped grant. Operator grants do not grant review rights. |
| `TaskReviewerRevokedV1` | Declared governance key; active reviewer grant in exactly the same scope. | Revocation is effective for later commands, including within a batch. |
| `TaskDoDDefinedV1` | Declared governance key; proposed task at expected version; 1–32 unique criterion IDs and descriptions. | Immutable definition event/revision; canonical criteria digest; new current definition clears previous submission/review. |
| `TaskEvidenceSubmittedV1` | Currently active scoped operator grant, matching principal and key; proposed task at expected version; exact current definition event. | Every criterion maps to exactly one SHA-256 artifact digest reference; a new current submission clears previous review. |
| `TaskDoDReviewedV1` | Active scoped reviewer grant, matching principal/key; expected task version and exact current definition/submission. | Signed `accept` or `refuse` decision with nonblank reason. Both principal and signing key must differ from the submitter. Only one review per submission. |

Each definition, submission and review advances the task's aggregate version.
The lifecycle state stays **proposed**, including after an accepted review.
This stage does not skip queueing, readiness, SOP, predecessor or execution
checks and does not implement completion. A review is not a deployment license.

Since [execution](2026-10-19-execution.md), submissions and reviews are also
admitted while a task is **in progress**, starting a task clears any earlier
submission and review, and `TaskCompletedV1` completes it by citing an
accepting review. A review still completes nothing by itself. A reviewer
grant may carry a `device_label`.

Criterion IDs use the existing bounded ASCII segment convention. Descriptions
and review reasons are nonblank UTF-8 strings of at most 2048 bytes. Evidence
maps must cover exactly the definition's IDs, with no omissions or extras;
values are 32-byte digest wrappers, not URLs, mutable rows or approval flags.
The native canonical envelope applies its existing total size/depth limits.

Artifact bytes remain outside the log. A digest reference is a signed claim,
not evidence that the server fetched, preserved or verified those bytes.
Acceptance records the reviewer's attestation, not an automatic correctness
proof. Artifact custody/receipt admission is a separate prerequisite for a
future completion contract. Do not represent evidence presence as satisfaction.

## Replay, review binding and retries

The existing task projection folds definitions, submissions, decisions and
reviewer grants. Direct `Log.append` receives the same admission rules as
`CoopSubstrate.Tasks.DoD.submit`. Its reply identifies the durable event/hash,
global watermark and task version. Single-command retries use the same signed
envelope and return the original receipt without append, even after revision
or revocation; changed signed bytes under an accepted ID are refused. Mixed
batch retry behavior is unchanged.

A later definition or submission changes the current projection, without
rewriting any earlier evidence or review in the ledger. A late reviewer cannot
approve a replaced submission or old criteria. Concurrent commands serialize
against committed task versions. Refusals can be followed by a new submission;
changing an existing decision in place is not supported.

## Buzz views

Scoped cards gain a `dod` object containing the current definition event/digest,
criteria, submission evidence references and exact review target/decision.
Existing top-level DoD text and `definition_ref` remain the preserved baseline
fields; consumers must use `dod` for the current structured revision.
Absent structured definitions yield `dod: null`. Rendering cards performs no
notifications or external effects and requires independently authorized reads.
Native Ed25519 envelopes remain distinct from Buzz/Nostr signatures.

## Validation

Tests were committed before implementation. Three isolated criteria/evidence
rules tests first failed for the missing module, then passed with implementation.
Together with the prior card/input tests, eight isolated tests pass locally on
Elixir 1.14/OTP 25. They do not replace the project's Elixir 1.19/OTP 27 and
PostgreSQL acceptance suite.

Acceptance tests exercise real EventStore append/replay/restart, direct-append
refusals, current definition/version binding, reviewer-versus-operator grants,
self-review across both principal and key, reviewer/operator revocation, atomic
batch rejection, superseded evidence/revisions, refusal and resubmission,
concurrent definitions, exact retries and conflicting IDs. The Consolidation
workflow checks all changed files and runs the full ledger/orchestration suites.
