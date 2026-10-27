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

| Obligation | Lean kernel statement | Quint bounded check | Not yet established |
| --- | --- | --- | --- |
| Prefix safety | `Safe`: every checkpointed ledger position has its durably registered effect bundle | `noPrematureCheckpoint`, `cursorWithinHead` | Real SQL effects/cursor transaction and EventStore integration |
| Guarded cursor advance | `acknowledge_preserves` requires effect already committed and cursor within head | `checkpoint` requires effect; `cursor_first_bug` must violate safety | SQL rejection of cursor-only write |
| Idempotent registration | `register_idempotent` (set membership) | `register` uses union, including duplicate registrations | External API side effects exactly once |
| Append does not acknowledge | `append_preserves` | `append` leaves cursor/effects alone | Verified EventStore append chronology under real transactions |
| Notification non-authority | `wakeOrCrash_preserves` | lost/bursty wakeups and restart preserve durable facts | Fair eventual catch-up and scheduler availability |
| Arbitrary transition safety | `step_preserves` for declared safe transitions | Bounded safety through Quint/Apalache | Absent real software refinement proof |

### Lean 4 — general mathematical safety

`formal/lean/BizKitEventProofs.lean` contains kernel-checked proofs for
the prefix invariant, registration idempotence and preservation under
appending, registering, acknowledging, wakeups and crashes. A theorem
provides a concrete counterexample for *cursor-first* acknowledgment.

This proof quantifies mathematically over event indices; it never
computes an infinite stream. **It proves properties of an abstract
transition relation, not properties of arbitrary Elixir/PostgreSQL code.**
No `sorry`, `admit`, untrusted axioms or `native_decide` are permitted.
CI pins Lean 4.35.0 and enables an axiom audit.

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

From `formal/quint` with a pinned `quint` CLI:

```sh
bash check.sh
```

The dedicated GitHub workflow
[EventStore consumer proofs](../.github/workflows/event-consumer-proofs.yml)
runs the Lean kernel/axiom audit and the Quint typecheck, simulation,
bounded model check and negative control. **Do not merge a runtime consumer
before its proof obligations and refinement tests are green.**

## Proof-to-implementation refinement ledger

**Phase 0 — proofs (this PR).** Establish a stable mathematical vocabulary:
committed `head`, acknowledged `cursor`, effect bundle per ledger event,
duplicate registration and crash/restart stuttering. Produce exact-head CI
evidence and review the negative control.

**Phase 1 — specify real event derivation.** Define a pure mapping from one
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
