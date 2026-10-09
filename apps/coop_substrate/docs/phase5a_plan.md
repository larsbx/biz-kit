# Phase 5A — The R-item rail + queue

> **Status: COMPLETE** (2026-07-11). Scope was the cockpit brief's Phase 5A; acceptance
> **[5A]** passes: an item missing any decision-ready element is unrepresentable
> (missing fields fail at envelope construction — stronger than planned — and hollow
> fields at the gate); the queue is a pure `{deadline_ms, item_id}`-ordered fold,
> `as_of:`-reproducible; flooding past the declared per-process cap rejects and the cap
> fails closed undeclared; a resolution closes exactly its open item once;
> `returned_defect` is terminal for the id (a fresh, complete item is the only path
> back). Both in-build corrections from the header stand (basis existence deferred to
> the flagged full rule; item-id tie order). `mix cockpit.queue` / `cockpit.decide`
> smoke-tested under the process shell. Normative outer authority: corpus 10 §5, §6
> P9–P12. Phase 5B (the boards) is next.

## §0 Spine

```
R item     unrepresentable unless decision-ready: packet refs, recommendation, bounds,
           compensation path, deadline + basis — required fields and gate checks
queue      = open items, a pure fold, deadline-ordered, as_of-reproducible
resolution = a signed act closing exactly its item; approved AUTHORIZES, never executes
flooding   structurally capped per process (declared constant, fails closed undeclared)
```

## Settled decisions

- **Two types on the item's own stream** (`<chapter>/escalations/<item_id>`):
  `EscalationRaised{item_id, process, act_type, packet_refs, recommendation, bounds,
  compensation_path, deadline_ms, basis_ref}` and `EscalationResolved{item_id, verdict ∈
  approved | declined | returned_defect, reason?}` — both steward-signed (the dedicated
  `operator` role stays the flagged one-line future change from the brief).
- **CORRECTION during build (basis verification):** the brief said the gate checks the
  deadline basis *exists*. It cannot, soundly: intra-batch envelopes have no stable
  `event_hash` before chain assignment, and the gate fold deliberately indexes domain
  state, not every event hash. v0 therefore enforces decision-ready **shape** —
  `basis_ref` is a required `:hash` field, `deadline_ms` positive, `packet_refs` a
  non-empty list — and basis *resolution* joins deadline *re-derivation* in the flagged
  full rule that lands with the first real deadline class. Logged here, and to be
  reflected in `COCKPIT.md` (5B).
- **CORRECTION (tie order):** the brief said "oldest-basis first on ties"; basis time is
  not tracked in v0, so ties order by `item_id` — deterministic, documented.
- **Flooding cap**: `cockpit/open_cap` via `CharterConstantDeclared` — v0 is one
  per-chapter cap applied per process (per-process caps when a process needs one,
  flagged); **fails closed**: no declared cap, no representable escalation (constants
  before first evaluation, as everywhere).
- **Resolution discipline**: item must exist and be open; closed verdict set;
  `returned_defect` closes the item and reopens nothing — the emitter raises a fresh,
  complete item (10 P10). Approval executes nothing: consuming domains reference the
  resolution in their own consequent events.
- **Surfaces**: fold state in the gate (`escalations` map, the 1C/2A extension pattern);
  `CoopSubstrate.Cockpit.queue/1` (open items, `{deadline_ms, item_id}`-ordered,
  `as_of:`) classified `:system`; `Ops.escalate/1` + `Ops.decide/3`;
  `mix cockpit.queue` and `mix cockpit.decide <item> <verdict> [--reason] [--yes]`
  (lax-direction ⇒ typed confirmation).

## Build steps (TDD)

1. Plan doc (this file) — commit.
2. Registry types + gate checks + fold state (escalations, open-count per process).
3. `Cockpit.queue/1`, `Ops.escalate/decide`, the two tasks; classification entry.
4. Tests: decision-ready shape rejections (missing fields at the registry, empty
   packet_refs / non-positive deadline at the gate); cap flooding (third open item
   rejected, a resolution frees the slot); resolution discipline (unknown item, double
   resolve, bad verdict, returned-defect finality); queue ordering + `as_of`; task smoke
   under the process shell.
5. Acceptance [5A] recorded; status flip — commit.

## Properties

```
P1  an item missing any decision-ready element is unrepresentable (shape v0, flagged)
P2  the queue is a pure fold: deadline-ordered, as_of-reproducible, closed items gone
P3  open items per process never exceed the declared cap; undeclared cap fails closed
P4  a resolution closes exactly its open item, once; verdicts are a closed set
P5  returned_defect is terminal for the item id — completeness must arrive as a new item
P6  no Ops/task-side validity logic (rejections verbatim, as everywhere)
```

## Adversarial

Flooding at the cap (rejected) · resolve-then-resolve (rejected) · escalation racing its
own resolution in one batch (batch order: event N sees N−1) · deadline forgery (shape v0:
typed basis_ref required; full derivation flagged) · a domain "approving" by appending
its consequent event without a resolution (its own gate's business — the rail only
guarantees the resolution exists to reference).

**Gate:** 5B (the boards) starts only when [5A] passes.
