# Authority lapse during a blocked activation (#296)

Status: **review packet; no policy selected, no runtime behaviour changed.**
It adds a regression, a Lean module and a Quint model. The runtime source under
`apps/dispatch/lib` is untouched. Evidence below was produced locally against a
disposable PostgreSQL cluster at the revision named in "Evidence"; it is not a
hosted receipt and promotes no verification status.

## The obligation

[E3_IMPLEMENTATION.md](E3_IMPLEMENTATION.md) states that locks order database
mutations relative to admission but do not freeze the clock, and that session
validity and grant expiry at the commit instant are not claimed. Issue #296
asks for a decision on whether session and time-bounded grant validity must
hold at HTTP admission, transaction admission or commit, with tests for a
transition blocked across expiry or revocation.

One statement in the issue is out of date at this revision. Board no longer
receives an actor "with no source-session credential": `Actor.authentication`
carries the subject, token expiry and a session *reference* for HTTP-originated
actors, and `MutationAuthority.transition/1` checks them at admission. It is
still `nil` for internally built actors, which are accepted without a session.

## Trace of `Board.transition(actor, id, "activate", version)`

Instants in order. "Clock" is a fresh `DateTime.utc_now/0`.

| # | Boundary | What is established | Can wait on |
| --- | --- | --- | --- |
| τ0 | HTTP admission (`ResolveActor`) | token verified; one assignment selected; `authentication` attached | nothing |
| τ1 | Board entry (`authorized/2`, unlocked) | grant re-read at a clock; capability | nothing |
| τ2 | transaction start; trip `FOR UPDATE`, load `FOR SHARE` | serialization on the trip | trip row, load row |
| τ3 | `authorized(lock: true)` | grant, definition, organization, participant share-locked and re-read at a clock | those rows |
| τa | `MutationAuthority.transition/1` | same rows locked again; **admission clock read after the locks**; grant interval, scope, constraints, token expiry, live Identity session | those rows; Identity singleton call |
| τp | `OperatorPolicy.activation/1` (twice: Board, then the resource guard) | load, participant, User, source role, definition, load-party share-locked; operator grant in force at its own clock | those rows |
| τw | `UPDATE … status = 'ACTIVE'` | occupancy, by the unique index and the exclusion constraint | **another transaction's uncommitted ACTIVE row, until it ends** |
| τu | audit append (`occurred_at = τa`) | hash chain | **tenant audit-chain advisory lock** |
| τc | commit | durability | WAL flush; the outer transaction when the idempotency ledger owns it |
| τr | response reload | nothing (separate read) | — |

Observations from the code at this revision:

1. Every authority check is at or before τp. Nothing is read between τw and τc.
2. The waits at τw and τu come after admission and are bounded only by the
   other transaction's lifetime. With an `Idempotency-Key` the ledger's
   `SET LOCAL lock_timeout = '3s'` applies to each wait separately; without a
   key there is no bound.
3. Board is not always the outermost transaction. Under the idempotency ledger
   the physical commit happens in `Idempotency.execute/4`, after Board returns.
4. Only `transition` calls `MutationAuthority`. `plan`, `create_load`,
   `update_load` and `add_stop` re-read the grant under locks but never check
   token expiry or the session inside the transaction.
5. Direct Ash lifecycle actions have no actor at all; they revalidate only the
   operator source.

## Three kinds of authority

| Kind | Examples | Ends by | Does the admitted transaction's lock hold it? |
| --- | --- | --- | --- |
| Recorded | grant revoked, definition changed, participant or User suspended, load-party ended | a database write | **Yes.** The write waits for the commit. |
| Clock-bounded | `role_assignments.ends_at` (actor and operator source), load-party lifetime, token `expires_at` | time passing | **No.** |
| External | Identity session expiry, logout, unbinding | a change in another store | **No.** |

So "revocation" is two different cases. A recorded revocation is already ordered
after the activation, including across the occupancy wait. A session logout is
not ordered at all.

## Candidate policies

Stated for an activation with admission τa and commit τc. None is chosen here.

| Policy | Requirement | Effect on a lapse inside (τa, τc) |
| --- | --- | --- |
| **A. Admission** (merged behaviour) | authority at τa | commits |
| **B. Bounded wait** | authority at τa and τc − τa ≤ Δ | commits if within Δ, else refused |
| **R. Recheck** | authority at τa and at a re-read after the waits | refused if seen at the re-read; commits if it lapses after it |
| **C. Commit** | authority at τa and at τc | refused |

Safety consequences:

- **A.** No new refusals. A committed activation can postdate its authority by
  an unbounded interval for unkeyed callers. A request from a logged-out
  session can still commit. The audit row shows τa, which was inside the
  authority's lifetime, and does not show when the commit happened.
- **B.** A lifetime has ended at most Δ before the commit
  (`bounded_lapse`). Contention now refuses legitimate work. A logout is still
  not honoured inside Δ. PostgreSQL's `lock_timeout` is per wait, so k waits
  allow k·Δ unless a deadline is carried.
- **R.** Closes both waits. A window remains between the re-read and the
  commit: returning through Ash, completing the idempotency claim, and the
  commit itself. It is short but not zero, and the session re-read is a second
  store that cannot be read atomically with a PostgreSQL commit.
- **C.** Exact only as a model. It is implementable for clock-bounded
  lifetimes if PostgreSQL's clock is the governing clock and the check runs
  inside commit processing. It is implementable for sessions only if session
  revocation becomes a lockable database row. The refusal then surfaces at
  commit.

Whichever is chosen, occupancy is unaffected: a temporal policy only refuses
more activations (`guarded_activation_safe`).

A fifth option changes the data instead of the check: treat expiry as a
recorded event written by a reaper. Lifetimes then behave like recorded
authority and A already equals C, but a grant stays effective until the reaper
commits, which changes the meaning of `ends_at`.

## Decisions requested

1. The governing instant for clock-bounded grant lifetimes: A, B (with which
   Δ), R or C. Whether the actor's grant and the operator's source grant are
   governed alike.
2. The same for token expiry and for Identity session expiry and logout.
   Whether an actor with `authentication: nil` may write through Board.
3. Which clock governs (application or database) and the tolerated skew.
4. Scope: activation only, every lifecycle transition, or every Board write.
   E3's contract says expiry does not cancel active work and that a carrier may
   still complete or cancel it "through an authorized Board action"; the same
   question therefore applies to releases.
5. What the caller is told when authority lapses after admission, and which
   instants the audit event records.

## Runtime regression

`apps/dispatch/test/dispatch/operations/board_authority_expiry_test.exs`,
using `Dispatch.Support.ConcurrentSessions` on independently committed
connections. `blockers/2` is added to that module.

Construction. A raw SQL session holds occupancy for the driver's User with an
uncommitted `ACTIVE` row. It takes no authority, audit or second-trip lock, so
the Board activation of a second trip can only wait at the index, which it
reaches after admission. The test observes `wait_event = 'transactionid'` with
the holder as the sole blocker, applies the change, observes the same wait
again, then rolls the holder back. The activation's outcome then depends only
on its authority.

| Scenario | Kind | How the lapse is produced |
| --- | --- | --- |
| `actor_grant_expiry` | clock | dispatcher grant `ends_at` passes |
| `operator_grant_expiry` | clock | driver's source grant `ends_at` passes |
| `token_expiry` | clock | `authentication.expires_at` passes |
| `session_expiry` | external | session deadline set in the past inside the Identity singleton |
| `session_logout` | external | `BizKit.Identity.logout/1` |

Each scenario is stated under both A and C and selected by tag, because only
one can hold: `--include temporal_policy:admission` characterizes the merged
runtime, `--include temporal_policy:commit` is the stronger statement and is
expected to fail until the runtime changes. Both are excluded by default.

Policy-independent controls run under `--include integration`:

- unchanged authority activates once the holder rolls back;
- a recorded revocation of the actor's grant, and separately of the operator's
  source grant, is observed blocked by the waiting activation, commits after
  it, and denies the next write;
- with an idempotency key the occupancy wait ends by itself after about 3 s
  and commits nothing.

Determinism. The three clock scenarios sleep, because the runtime calls
`DateTime.utc_now/0` directly and offers no clock to substitute. Each run
proves its own ordering instead of assuming it: admission is observed before
the lapse and the wait is observed after it, otherwise the test fails as
inconclusive. The two session scenarios and all controls use no sleep.

Not covered: the audit-chain advisory wait at τu, load-party lifetime,
session unbinding, release transitions, `plan`, and the direct Ash writer.

## Formal models

`formal/lean/BizKitDriverAuthorityTime.lean` treats authority as a predicate
on instants and the four policies as predicates on an activation's
(admitted, checked, committed) instants.

- Order: C ⇒ R (for convex authority, which every lifetime interval is),
  R ⇒ A, B ⇒ A, and B with Δ = 0 ⇒ C.
- Separation: one activation that waited witnesses A ⇏ R, R ⇏ C, B ⇏ C and
  C ⇏ B.
- `Frozen` is the premise a held row lock supplies. Under it A ⇔ C for
  recorded authority (`frozen_admission_iff_commit`), and C for mixed authority
  reduces to one further read of the unfrozen part at the commit instant
  (`commit_reduces_to_unfrozen`). A lifetime is not frozen
  (`lifetime_not_frozen`).
- Any policy guard composed with the existing activation is still a `Step`, so
  E3 safety is preserved.

`formal/quint/dispatch_e3_authority.qnt` models two conflicting assignments, a
clock, the index wait, a lock-respecting revocation and an external session.
`check_dispatch_e3_authority.sh` asserts every cell of this matrix:

| Step relation | `baseline` | `commitAuthority` | `boundedStaleness` | other |
| --- | --- | --- | --- | --- |
| A `step` | holds | refuted | refuted | |
| B `boundedStep` | holds | refuted | holds | `boundedClockLapse` holds |
| R `recheckStep` | holds | refuted | | `recheckAuthority` holds |
| C `commitStep` | holds | holds | refuted | |
| control `unlockedStep` | | | | `revocationOrdered` refuted |

`baseline` is occupancy, admission-time authority and ordered revocation. Each
relation is also shown non-vacuous: an activation that waited does commit.

Limits. Instants are naturals on one clock. C evaluates authority atomically
with the commit, which no application can do against a wall clock or another
store. Neither model refines Elixir, Ash or PostgreSQL, and neither claims
liveness, fairness or deadlock freedom.

## What the runtime interface would need

For anything stronger than A:

1. **Validity horizons out of admission.** `MutationAuthority.transition/1`
   returns an actor and `OperatorPolicy.activation/1` returns `:ok`. Neither
   reports the earliest instant at which what it validated lapses (grant
   `ends_at`, load-party end, token `expires_at`) or the session reference.
   Without that, a later check must repeat every read.
2. **A confirmation point after the waits.** Nothing runs between the audit
   append and the commit. R needs a step there that re-reads the clock against
   the horizons and re-asks Identity about the session.
3. **The outermost transaction.** Under the idempotency ledger Board cannot
   run a last check before the physical commit. Either the ledger invokes a
   guard that Board hands back, or the check moves into the database.
4. **A clock that can be supplied.** `MutationAuthority`, `OperatorPolicy` and
   `Driving` read `DateTime.utc_now/0` directly. A clock parameter is needed to
   test expiry without sleeping and to make "which clock governs" a choice.
5. **For C on lifetimes:** a stored horizon on the transition's audit row and
   a deferred constraint trigger comparing it with the database clock at
   commit. This is a schema change with its own approval. PostgreSQL 16 has no
   `transaction_timeout`.
6. **For C on sessions:** revocation recorded in PostgreSQL as a row the
   admitted transaction share-locks, so that logout orders like a grant
   revocation and `Frozen` applies.
7. **For B:** a deadline carried across waits, and a bound on unkeyed writers.
8. **Audit.** `occurred_at` is τa. Recording the confirmation instant and the
   horizon alongside it would let the audit show which instant governed.

## Finding outside the policy question

When a keyed activation times out on the occupancy wait, Board returns
`{:invalid, "* Dispatch.Fleet.Assignment - the resource is not available:
canceling statement due to lock timeout."}`. The controller maps `:invalid` to
HTTP 422 with that text. Ash converts the Postgrex error before the ledger's
`lock_timeout?/1` rescue can see it, so the ledger's `:in_progress` answer is
not reached. E3 specifies a single generic refusal for occupancy; this is a
second, retryable condition with an internal message. The control test asserts
only that the write is refused and commits nothing.

## Evidence

Local, at `bcc7f1ca45dab5756162978717b7d396172a9b22` (main, containing merge
`c142e6f0` of PR #326) plus the changes of this packet, before they were committed. PostgreSQL
16.15 with PostGIS 3.4.2 in a newly initialized throwaway cluster; Erlang/OTP
27.3.4, Elixir 1.19.0, Lean 4.35.0, Quint 0.32.0.

| Check | Result |
| --- | --- |
| Baseline `scripts/dispatch/check-e3-database.sh` (unchanged) | passed, 11 SQL concurrency cases |
| Baseline `formal/quint/check_dispatch_e3.sh` (unchanged) | passed: 16 tests, verification through 8 steps, 5 controls refuted |
| Baseline workflow runtime list, before this packet | 214 tests, 0 failures |
| Workflow runtime list including the new file | 218 tests, 0 failures, 10 excluded |
| New file, `--include integration` | 4 tests, 0 failures |
| New file, `--include temporal_policy:admission` | 5 tests, 0 failures |
| New file, `--include temporal_policy:commit` | 5 tests, **5 failures**, each at `assert {:error, _} = run.result`; none inconclusive |
| All of `apps/dispatch`, `--include integration` | 669 tests and 2 doctests, 0 failures, 10 excluded |
| `check_dispatch_e3_authority.sh` | 15 directed tests; 8 cells hold through 10 steps; 10 cells refuted |
| `BizKitDriverAuthorityTime` | full `formal/lean/check.sh` passed: build, fresh kernel replay, 86 declarations audited within `propext`, `Classical.choice`, `Quot.sound` |
| `scripts/formal_coverage_audit.py` and its unit tests | no problems; 15 tests pass |

The admission and commit selections were run five times with different
seeds and gave the same counts each time.

The five commit-policy failures are the measured form of the gap: on real
PostgreSQL, each lapse during the occupancy wait is followed by a committed
activation whose audit instant precedes the lapse.

Deviations from the hosted workflow: PostgreSQL ran from distribution packages
instead of the `postgis/postgis:16-3.4` image, and the Lean archive, after the
install script verified its pinned SHA-256, was unpacked with Python's
`zstandard` because the `zstd` binary was not yet installed. The 172 and 568
counts in PR #326 belong to its own head; the counts above belong to a later
main and are not comparable with them.
