# Phase 8B — Dispatch-D under simulation: dispatch + tracking (the 4B slice)

> **Status: COMPLETE** (2026-07-20). Second sim slice under the 8A
> authorization (operator-directed: all three remaining sim slices).
> Acceptance **[8B]** passes: loads descend only from accepted tenders,
> one per tender (1); per-stop ordering gate-enforced — no departure
> without arrival, nothing twice, no backwards time, appointments frozen
> at arrival (2); `Dispatch.dwell/2` folds signed payload times (3);
> check-call types and modules structurally absent (4); load streams
> member-keyed, queries classified (5). Same rules as 8A: the machinery
> is real, the gate untouched, nothing simulated is field evidence, and
> the real `phase4b` transcribes the real adopted spec when it exists.

## Grounding

- `docs/handoff_dispatch_d.md` §2 Phase 4B: `LoadDispatched` (assignment
  inside the carrier's own envelope), `StatusRecorded` (telematics ingest —
  import-shaped, connector-free), `AppointmentRecorded`,
  `LoadArrived`/`LoadDeparted` (the 07 §3 interchange pattern on the
  carrier's own stream). Acceptance [4B]: a load's lifecycle is an unbroken
  event sequence; dwell is a fold; **no check-call machinery exists**
  (10 §4.1: check calls are deleted, not automated).
- Phase 8A's tender rail: a load exists only downstream of a
  `TenderAccepted` — the accepted tender IS the in-envelope assignment
  evidence for v0 (the decision already carries envelope version + basis).

## Acceptance [8B]

1. **Loads descend from accepted tenders only.** `LoadDispatched` is
   representable only for an accepted, not-yet-dispatched tender of the
   same member/entity; one load per tender.
2. **The lifecycle is an unbroken, ordered sequence.** Per stop
   (`pickup`/`delivery`): arrival before departure, each at most once,
   departure time ≥ arrival time; appointments re-recordable (reschedules)
   until arrival. Out-of-order events are rejected before persistence.
3. **Dwell is a fold.** `Dispatch.dwell/2` computes per-stop
   arrived/departed/appointment times and dwell minutes purely from the
   log; no clock reads — event time comes from signed payloads.
4. **No check-call machinery.** No check-call event type is registered and
   no scheduler exists — asserted structurally.
5. **Sovereignty + classification.** Load streams are member-keyed (ride
   the 6B bundle); new queries classified in the no-surveillance surface.

## Build steps

1. Add this plan and commit before implementation.
2. Registry: `LoadDispatched`, `AppointmentRecorded`, `LoadArrived`,
   `LoadDeparted`, `StatusRecorded` — steward-signed (operator import,
   connector-free), stream-keyed `loads/<member>/<entity>`.
3. Projection: `loads` map (tender ref, per-stop appointment/arrival/
   departure, status trail); tenders gain a `dispatched` marker.
4. Gate checks: acceptance 1–2 as type_checks (the 8A pattern).
5. `Dispatch.dwell/2` (own_data) + no-surveillance entries.
6. `test/dispatch_tracking_test.exs` on the 8A sim world; full suite;
   commit only if green.

## Explicitly deferred

- Detention arithmetic (needs declared free-time terms — 8C).
- Cross-party yard interchange chains (a later brief per 4B).
- Telematics connectors (the brief's explicit v0 exclusion — import only).
