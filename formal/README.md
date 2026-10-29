# Proof-driven EventStore consumer alignment (Lean 4 + Quint)

Status: **proof-first PR, no production or Elixir implementation changes**.
Authority: [CoopSubstrate.Log](../apps/coop_substrate/lib/coop_substrate/log.ex);
target: [platform alignment #161](https://github.com/larsbx/biz-kit/issues/161)
and [agent coordinator #92](https://github.com/larsbx/biz-kit/issues/92).

The EventStore source is the signed, append-only `ledger` stream **per
independently administered business home**. The consumer is a non-authoritative
operational projection. An ActivityPub peer has its own ledger; foreign
notifications do not license writes at the receiving home.

## Formal models and what they actually establish

The [TigerBeetle outcome-admission proof target](../docs/architecture/2026-10-29-tb-outcome-admission-proof-target.md)
adds `BizKitOutcomeAdmission.lean` and `tb_outcome_admission.qnt`: exact
source-slot/body binding, one durable business append per original operation,
independent destination cursors and lost-reply recovery. This separate model
uses **one-based complete-group ordinals** throughout; `Source.anchor` maps
them to original native IDs. It assumes an immutable verified source snapshot
and does not implement Log admission or cryptographic verification.

| Obligation | Lean kernel statement | Quint bounded check | Not yet established |
| --- | --- | --- | --- |
| Prefix safety | `Safe`: every checkpointed ledger position has its durably registered effect bundle | `noPrematureCheckpoint`, `cursorWithinHead` | Real SQL effects/cursor transaction and EventStore integration |
| Guarded cursor advance | `acknowledge_preserves` requires effect already committed and cursor within head | `checkpoint` requires effect; `cursor_first_bug` must violate safety | SQL rejection of cursor-only write |
| Idempotent registration | `register_idempotent` (set membership) | `register` uses union, including duplicate registrations | External API side effects exactly once |
| Append does not acknowledge | `append_preserves` | `append` leaves cursor/effects alone | Verified EventStore append chronology under real transactions |
| Notification non-authority | `wakeOrCrash_preserves` | lost/bursty wakeups and restart preserve durable facts | Fair eventual catch-up and scheduler availability |
| Arbitrary transition safety | `step_preserves` for declared safe transitions | Bounded safety through Quint/Apalache | Absent real software refinement proof |

### Additional proof obligations — lease fencing and complete effect bundles

The EventStore consumer must handle **zero, one or multiple** derived effects
per accepted event. A single `effect registered` flag can hide a partial
write. The stronger `BizKitBundles.lean` proof defines:

```text
BundleReady(s, position) =
  DurableProcessedReceipt(s, position)
  ∧ ∀ effect, Required(s, position, effect) → Registered(s, position, effect)
```

A cursor advance is permissible only after the *entire* required bundle and
its processed receipt have committed. For a zero-effect event the receipt
remains mandatory. This is a proof of an abstract condition, **not** proof
that the SQL effects and cursor actually share a transaction.

`effect_bundles.qnt` checks a three-event scenario with two effects at
position 1, **zero** at position 2 and one at position 3. Its
`bundle_partial_bug.qnt` negative control loses the second effect when the
cursor is advanced after inserting only the first.

Separately, `BizKitLeases.lean` proves the CAS generation and cancellation
boundary for one operational effect. A stale competing claimant cannot
reuse the claimed row version, and cancellation invalidates the old holder.
`lease_fencing.qnt` explores two independent workers and crash-stutter
without silently freeing a lease. `lease_crash_bug.qnt` deliberately
forgets the backend launch during restart and must expose a duplicate
external launch. Neither model assumes a particular agent framework,
backend, volume manager, nor vendor.

The strengthened Lean `atomicBundleCommit_preserves` theorem models
**one indivisible commit** of every required effect, the processed receipt,
and the cursor watermark. `formal/quint/cursor_transaction.qnt` provides a
second, more operational refinement model with separate volatile staging,
a commit action and crash/rollback. Its safety conditions prohibit any
**committed partial effect bundle**. A staged partial bundle is allowed,
but rollback must leave both the durable cursor and effects unchanged.
The bounded verifier explores ten steps for this model so it can reach a
two-event history containing a no-op receipt.

This strengthens the formal **target contract**, not the existing runtime:
the actual `Postgrex` implementation must implement these three writes in
one transaction under a current row-version predicate. Committing
`agent_ops` state through independent SQL statements and advancing the
cursor afterward without transactional rollback would not establish the
proved atomic-refinement property. Cross-instance home scope and real
signed-envelope provenance are extra authorization assumptions.

The **negative controls must be observed as violations** in CI; writing
them alone is not evidence of successful model checking.

### Lean 4 — general mathematical safety

`formal/lean/BizKitEventProofs.lean` contains kernel-checked proofs for
the prefix invariant, registration idempotence and preservation under
appending, registering, acknowledging, wakeups and crashes. A theorem
provides a genuine counterexample for *cursor-first* acknowledgment after one event has already been committed.

This proof quantifies mathematically over event indices; it never
computes an infinite stream. **It proves properties of an abstract
transition relation, not properties of arbitrary Elixir/PostgreSQL code.**
No `sorry`, `admit`, untrusted axioms or `native_decide` are permitted.
CI installs the SHA-256-pinned Lean 4.35.0 release archive, rebuilds from
source, replays the entire imported environment with `leanchecker --fresh`,
and audits declarations defined in **each** library module, including the
separate outcome-admission module.
`leanchecker` uses Lean's kernel; it is not a different kernel implementation.

### Quint — finite adversarial histories

`formal/quint/event_cursor.qnt` models up to three committed events and
nondeterministic registration order, duplicate registration, checkpoint
advance, unreliable notifications and crash/restart. The checked
`safety` invariant requires a gapless durable prefix.

`formal/quint/cursor_first_bug.qnt` is a deliberately incorrect design
in which the consumer advances its cursor before materializing its effect.
The check script must find a **real invariant violation** on that model;
a tool/typecheck failure is not acceptable as counterexample evidence.
Two nonvacuity witnesses require reachable staged/out-of-order states.

Quint/Apalache checks are **bounded**. Their successful execution is not an
unbounded proof of arbitrary database histories, cryptographic admission,
network liveness or backend finality. Lost notification recovery requires a
periodic/fair replay or durable cursor worker that actually runs.

## Executable checks

From `formal/lean`:

```sh
lake build
```

For the full CI checks on Linux x86_64, starting at the repository root:

```sh
bash formal/lean/install-toolchain.sh /tmp/bizkit-lean
export PATH="/tmp/bizkit-lean/bin:$PATH"
bash formal/lean/check.sh
```

The installation directory must be new. The installer downloads directly
from the official GitHub release (bypassing the failed release redirect),
retries transient download failures with TLS verification enabled, and
checks the committed SHA-256 **before extraction**. `BIZKIT_LEAN_ARCHIVE_CACHE`
can name an offline archive cache; cached bytes undergo the same check on
every installation. CI caches only that archive, never compiled project
proofs. A corrupt cache or unavailable download fails the installation gate;
neither is a proof result. The full audit also needs access to the pinned
`axiom-audit` source commit. Quint needs its evaluator and Apalache/Java.

Formal and PostgreSQL workflows check out the literal PR head and log its
SHA. Formal, cursor, signed-source and storage changes run both acceptance
lanes; Consolidation continues to run the real signed-source tests. Compare
all three runs on the same head before integrating a future change.

From `formal/quint` with a pinned `quint` CLI:

```sh
bash check.sh
```

The dedicated GitHub workflow
[EventStore consumer proofs](../.github/workflows/event-consumer-proofs.yml)
runs the Lean kernel/axiom audit and the Quint typecheck, simulation,
bounded model check and all three negative controls. **Do not merge a runtime consumer
before its proof obligations and refinement tests are green.**

## Index convention and refinement boundary

The Lean modules use **zero-based indices**: committed entries are
`0 .. head - 1`, and `cursor` is the exclusive end of a processed prefix.
The Quint specifications use event positions **1 through head**, where
`cursor` is the greatest acknowledged sequence or zero. EventStore's
`global_seq` is also one-based. Thus:

```text
Lean index n         = EventStore.global_seq - 1
Quint event position = EventStore.global_seq
All cursor values    = number of consecutively completed ledger events
```

An operational consumer stores `cursor` as a **one-based ledger watermark**
(0 before any event); a pure Lean transition for index `n` corresponds to
SQL accepting `global_seq = n + 1`.

This mapping is essential: a SQL cursor advanced by one without an
atomic **complete effect bundle + processed receipt** contradicts both the
Lean invariant and Quint safety. The model assumes one independently
administered home; every cursor/receipt/effect identifier must also be
scoped to that home to prevent cross-installation collisions.

**Proof scope and authority contract:** these models assume the appender
has *already* verified the canonical envelope, signatures and chain.
No event notification, foreign federation payload or model output may
supply authoritative `global_seq` to the consumer. The host must retrieve
accepted events through the trusted EventStore read API, not accept
indices from a message body.

## Proof-to-implementation refinement ledger

**Phase 0 — proofs (this PR).** Establish a stable mathematical vocabulary:
committed `head`, acknowledged `cursor`, effect bundle per ledger event,
duplicate registration and crash/restart stuttering. Produce exact-head CI
evidence and review the negative control.

**Phase 1 — specify real event derivation.** The complete-bundle and
processed-no-op rules above must be reflected in every derived event type. Define a pure mapping from one
accepted signed `CoopSubstrate.Protocol.Envelope` at `global_seq` to zero
or more tenant-scoped operational effect IDs. A zero-effect event still
needs a durable *processed* receipt. Reject unknown event types/versions
rather than silently skipping required effects. Keep one coherent identity
per aggregate and one effect owner.

**Phase 2 — cursor/registration atomicity.** Add one `agent_ops` (or
existing operational-storage family) cursor table keyed by the subscriber
and business home. In a single PostgreSQL transaction under compare-and-swap
or row lock, register all derived effect IDs (or a durable no-op receipt)
**then** advance cursor, fenced to the observed global sequence.
On failure rollback both. A stored cursor must never refer to an event
whose required effects are absent. No second authoritative ledger.

**Phase 3 — catch-up and live signals.** Read bounded pages from
`CoopSubstrate.Log.read_all(from: ..., as_of: ...)`, compare with the
committed ledger head, persist effects + cursor, and repeat after restart.
`CoopSubstrate.Feed` `:pg` events wake the consumer only. Out-of-order,
missed or forged in-memory notifications never license a command.
Use current TaskCore scoped grants and administrator-approved profiles for
every candidate launch.

**Phase 4 — implementation correspondence.** For every Lean transition,
provide a named Elixir/SQL operation and an isolated PostgreSQL test. For
every Quint scenario, provide a concurrency/restart fault-injection test:
before effect insert, after insert/before cursor update, after commit/before
ack, duplicate delivery, cursor lag and producer append during catch-up.
Track the exact code and proof revision that were jointly accepted.

**Phase 5 — external effects and release.** Demonstrate durable effect-ID
deduplication, recovery of unknown backend handles, signed/grant-aware
cancellation, candidate custody without unauthorized DoD completion, and
real local/remote agents through the same engine-neutral port. Then
complete historical writer fencing, Dispatch/Keel and domain cutovers
tracked in issue #161. Production activation is a separate gate.

## Non-goals

No second EventStore, global federation ledger, redefinition of existing
cooperative signatures, arbitrary agent-framework coupling, direct model
business writer, production Podman/Docker switch, or automatic migration
of legacy business rows. This PR intentionally makes **no** claim that
the whole platform or its actual database implementation has been proved.
