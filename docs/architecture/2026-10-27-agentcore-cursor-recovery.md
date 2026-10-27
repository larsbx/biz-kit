# Staging global_seq discovery recovery

Status: **independently testable draft; no production activation or backend
cutover.** Merge after exact-head acceptance of #159, #160, #165 and the
Lean/Quint protocol in #162, then rerun the combined exact-head checks. The
formal protocol is abstract; this code is not a machine-checked refinement.

## Contract and authority

`CoopSubstrate.AgentEventCursor.catch_up/5` takes a trusted staging host, stable
configured business-home/subscriber identities and a page size from 1 to 1000.
It accepts no notification or external event payload. It reads the existing
Log head, anchors a resumed cursor to the canonical prefix hash, audits the
observed prefix against the appender head, and uses bounded
`Log.read_all(from:, as_of:)` pages. Appends after the observed head wait for
another invocation. A partial pass resumes at its durable checkpoint.

`AgentEventEffects` verifies each envelope's signature/schema and derives one
conservative reconciliation discovery ID per known event, scoped to its
project when present and otherwise to its chapter. This over-approximation
also catches chapter-wide authority changes. The inert `TestProjectionEvent`
produces a durable zero-effect processed receipt. Unknown types/versions,
gaps, reordering and broken hash links stop progress. No task data, arbitrary
payload, prompt, adapter handle or credential is stored in these rows.

Migration 004 creates only `agent_ops.event_cursors` and
`event_registrations` in the existing database. Each registration is the whole
discovery bundle for one event. It is not an execution-attempt row and confers
no authorization. The existing Coordinator still performs fresh signed state,
read/execute grants, profile/consent checks, lease CAS and post-claim authority
recheck before launch. No second business ledger is introduced.

## Correspondence with the #162 abstract protocol

| Abstract transition/obligation | Implementation | Acceptance |
| --- | --- | --- |
| `append` leaves cursor unchanged | Existing Log; explicit catch-up only | Producer append between pages; lost notification case |
| `register` is idempotent | `commit_event_registration` compares immutable event/hash/scope identity | Duplicate and conflicting duplicate SQL tests; independent connection race |
| `acknowledge` requires registered bundle | SQL inserts registration/no-op receipt before cursor UPDATE in one transaction | Prefix trigger rejects direct cursor-first UPDATE |
| Gapless safe prefix | Cursor starts at zero; row lock, expected sequence/hash, next sequence only | Gap rejection and history-mismatch tests |
| Crash/wakeup is a durable-state stutter | Nothing authoritative in process memory; no notification argument | Outer rollback, forced database connection termination, resumed bounded replay |
| Failed commit preserves both sides | SQL statement/outer transaction rollback | Trigger abort after insert/before checkpoint, no residual registration/cursor |
| No-op still processed | Null discovery ID with strict all-null scope shape | Durable hash-bound no-op receipt; malformed partial no-op refused |

The SQL commit function is SECURITY DEFINER with a fixed catalog/temp search
path and schema-qualified objects. Its protected migration owner must differ
from the runtime host role. PUBLIC gets no table/function access; a reviewed
host role gets SELECT and function EXECUTE, without cursor/registration DML.
The SQL contract tests both allowed EXECUTE and denied direct mutation. Database
superusers and migration owners remain trusted; their compromise is outside
this invariant. There is no production role provisioning in this change.

## Evidence and gates

Locally passed: three pure derivation/chain tests; the six operational unit
tests; the 105-test TaskCore suite (including the previously failing lease gate); warnings-as-errors compilation; formatting and diff checks. All four
migrations and all four SQL contract scripts passed PostgreSQL-in-WASM using
PGlite 0.5.12. That local SQL check is NOT native PostgreSQL 16 concurrency,
connection-crash, Docker-volume or Podman acceptance.

The existing volume CI now applies migration 004, runs the SQL fault/privilege
contract, exercises native independent-connection cursor races and connection
termination, and checks both cursor and registration after container recreation.
The signed-ledger workflow additionally exercises bounded actual committed
replay, restart, lost notification recovery, producer appends, no-op receipts,
production refusal and wrong-history refusal. Hosted exact-head jobs must pass
before these draft increments can merge. Queued jobs are not passing checks.

## Remaining limitations

Discovery registrations are persisted but NOT automatically drained into the
execution coordinator. The existing periodic full-state scan remains the
execution and revocation fallback. A later accepted increment must claim/drain
these discovery scopes and handle acknowledgment without losing current-state
reconciliation. No production subscriber is started by this code.

The complete observed prefix is audited on each call. Page allocations are
bounded, but audit CPU/I/O is not proportional to page size; this is deliberately
an unoptimized staging safety boundary. Event registration is conservative and
may request more reconciliation than necessary. Pruning, audit/checkpoint
optimization, stable deployed home identity, protected runtime grants and
operational scheduling remain release work.

Real adapter idempotency, independent signed backend finality/absence receipts,
runtime credential confinement, typed business-tool authority, evidence custody,
real distinct backend conformance, rollback and production release remain in
#92. No container or agent framework is chosen here; Docker/Podman Compose and
the approved ExecutionPort/RecoveryPort contracts are preserved. Rootless Podman
execution still requires its own host acceptance. General agent business writes
remain disabled.
