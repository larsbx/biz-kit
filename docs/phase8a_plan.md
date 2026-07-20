# Phase 8A — Dispatch-D under simulation: sim gate(D), envelope machinery, tender rail

> **Status: PLANNED** (2026-07-20). Operator-directed (2026-07-20: "mock the
> gated blockers to advance with simulations and testing"): advance the
> Dispatch-D *machinery* (docs/handoff_dispatch_d.md Phase 4A slice) against
> a **simulated** gate(D), without weakening the gate or presenting
> simulation as field evidence.

## The deviation, flagged honestly

The dispatch brief cuts the real 4A only after `gate(D)` goes true on real,
consented field data, and where the adopted spec and the brief conflict the
spec governs. Neither exists yet. This phase therefore:

- drives `gate(D)` true **through the real 2A–2D machinery** on a sim
  chapter (`chapter-sim-1`) with clearly-synthetic actors and data — the
  exact path the [2D] acceptance test already proves — so `BuildStarted(D)`
  lands *legitimately over that synthetic log*; the gate itself is not
  touched, and a control test proves `BuildStarted` stays unrepresentable
  on a chapter whose gate is false;
- reserves `docs/phase4a_plan.md` for the real build: when real field data
  arrives, real-4A transcribes the real adopted spec and re-derives this
  slice from it (the brief's own rule), keeping or replacing what 8A built;
- leaves the gate-out (the D slice live on the first hub's books, 13 §6)
  field-gated: nothing simulated may feed the founder campaign, outreach,
  or any [SECURITIES]/counsel-governed surface.

## Grounding

- `docs/handoff_dispatch_d.md` §0 invariants 1–4/6, §2 Phase 4A, §3.
- `docs/corpus/10_AUTONOMY.md` §0–§5 (envelope = signature and ceiling;
  A decisions pure functions of (log, envelope version); out-of-envelope ⇒
  R escalation, never auto-act; demote on low-grade inputs).
- `docs/corpus/08_PLATFORM.md` §3/§7 (graded verification; parses never
  authoritative; the published fixture set is the parser TDD corpus).
- Existing machinery reused: the 2A–2D pipeline (`Harness.*`), the 5A
  R-item rail (`EscalationRaised` — out-of-envelope tenders raise generic
  R items, `item_id: "tender/<id>"`), `Harness.Artifacts` for raw tender
  bytes, the 6B export keying (envelope/tender streams are member-keyed,
  so they ride the departure bundle automatically).

## Acceptance [8A]

1. **Sim, not bypass.** `CoopSubstrate.Sim.GateD.run/1` drives `gate(D)`
   true on the sim chapter through the real pipeline (constants, consents,
   instrument, interviews, findings, corroboration, document, model, spec,
   adoption, fixture set) and `BuildStarted{section: "D"}` appends; on a
   chapter without that evidence `BuildStarted` is still rejected.
2. **Envelope is the member's signature and ceiling.** `EnvelopeDeclared`
   (scope `tender_accept`: lanes, equipment, rate_floor_minor) is valid
   only self-signed with the member's current key; versions are strictly
   monotonic; `EnvelopeRevoked` is atomic — decisions after revocation can
   only escalate.
3. **Routing is unrepresentable when wrong.** `TenderAccepted`/
   `TenderDeclined` append only when they equal the pure decision
   (`Dispatch.decide/2`) recomputed by the gate from its own fold —
   in-envelope at/above floor ⇒ accept, in-envelope below floor ⇒ decline,
   off-lane/off-equipment or no active envelope or machine-graded parse ⇒
   escalate only. Decision events carry envelope version + basis.
4. **Parser green against the published fixture set.** The v0 line-format
   parser passes over every fixture in the sim-published (anonymization-
   gated) fixture set, fetched by hash.
5. **Sovereignty + no surveillance.** Envelope and tender streams are the
   member's own (registry-keyed into the 6B bundle); every new public
   query function is classified in the no-surveillance surface.

## Build steps

1. Add this plan and commit before implementation.
2. `CoopSubstrate.Sim.GateD` (`lib/coop_substrate/sim/gate_d.ex`,
   simulation-only moduledoc): the 2D pipeline as a callable, returning the
   sim actors/hashes; seeds the sim carrier membership; declares
   `cockpit/open_cap` for the R rail.
3. `CoopSubstrate.Dispatch.Parser` — deterministic `key: value` tender
   parser (lane, rate_minor, equipment); no LLM, no frontier refs.
4. `CoopSubstrate.Dispatch` — `decide/2` (pure) and `route/2` (log-derived).
5. Registry + gate + fold: `EnvelopeDeclared/Revoked` (member-signed,
   monotonic, atomic revocation), `TenderReceived` (raw hash) →
   `TenderParsed` (graded, machine re-parseable to human — the 08 §7
   promotion) → `TenderAccepted/Declined` (gate recomputes the decision);
   membership projection gains `dispatch_envelopes` and `tenders`.
6. No-surveillance classification for `Dispatch` and `Dispatch.Parser`;
   SUBSTRATE.md §17 consumer list gains Dispatch.
7. `test/dispatch_sim_test.exs` covering acceptance 1–5; full suite green;
   commit only if green.

## Explicitly deferred

- Post-approval consumption of a tender escalation (an approved R item
  authorizing a manual accept) — the R-rail's consuming-domain contract,
  next slice.
- Phases 4B–4D machinery (dispatch/tracking, invoice/detention/dunning,
  demo kit) — subsequent sim slices only on direction.
- `DISPATCH.md` normative doc — written when the real 4A transcribes the
  real spec; until then this plan is the authority for the sim slice.
- Everything the brief defers: connectors, counsel-gated dunning wording,
  HOS feasibility, rate-confirmation countersign.
