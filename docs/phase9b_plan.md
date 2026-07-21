# Phase 9B — R-approval consumption: the tender rail consumes its escalations

> **Status: PLANNED** (2026-07-21). Scope is the 8A plan's stated next
> slice: "Post-approval consumption of a tender escalation (an approved R
> item authorizing a manual accept) — the R-rail's consuming-domain
> contract." The 5A brief defines the producing half ("Approval
> AUTHORIZES — consuming domains append their own consequent events
> referencing the resolution; nothing executes here"); nothing consumes
> it today. Not blocked by `gate(D)`; no new event types; sim-arc rules
> unchanged (real machinery, untouched gate).

## Grounding

- `docs/phase8a_plan.md` deferred list (the stated next slice) and the 8A
  invariant: out-of-envelope and low-grade routes reach only the R rail.
- `docs/handoff_cockpit.md` / type registry 5A note: approval authorizes;
  consuming domains append their own consequent events referencing the
  resolution.
- `docs/corpus/10_AUTONOMY.md` §5: the R queue is where humans decide what
  automation may not; the decision's provenance must stay on the log.

## Design decisions (flagged)

1. **The authorization reference is structural.** `TenderAccepted`/
   `TenderDeclined` gain an optional `authorization_item_id`; the gate
   requires it to be exactly `"tender/" <> tender_id` (the 8A convention,
   now enforced at consumption — id construction, not stream parsing) and
   the cited item to be resolved with verdict `"approved"` on process
   `tender_accept`.
2. **The authorized path exists only where the pure function ends.** An
   authorization is consumable only when `Dispatch.decide/2` still says
   escalate; if the world changed and the function now decides, the
   normal recompute path governs and citing an authorization is rejected
   (`:authorization_not_needed`). The two paths never overlap.
3. **Authorized decisions are marked, not disguised.** They carry
   `envelope_version: 0` (this decision did NOT come from the envelope
   function — it came from a human R resolution) and
   `basis: "r/" <> item_id`, both gate-enforced, so replay distinguishes
   machine decisions from authorized ones forever.
4. **One shot per tender.** The `tender/<id>` item id is unique, verdicts
   are final, and `tender_already_decided` still applies — an approval
   authorizes at most one decision event. Re-raising after a declined
   resolution is deferred (re-raise semantics are R-rail policy).

## Acceptance [9B]

1. An approved `tender/<id>` resolution makes exactly one authorized
   `TenderAccepted` (or `TenderDeclined`) representable on that tender —
   with `envelope_version` 0 and `basis` `"r/tender/<id>"`; wrong basis,
   wrong version, wrong item id, unresolved item, or a `declined`/
   `returned_defect` verdict all reject before persistence.
2. Without a cited authorization, escalate-route tenders stay
   unrepresentable exactly as in 8A (regression-pinned).
3. Citing an authorization when the pure function decides is rejected;
   the authorized decision cannot masquerade as a machine decision.
4. The consumed decision closes the tender normally (`decided` set, load
   dispatch downstream works); chains verify; the classification surface
   is unchanged (no new queries).

## Build steps

1. Add this plan and commit it before implementation.
2. Registry: optional `authorization_item_id` on `TenderAccepted`/
   `TenderDeclined`.
3. Gate: the authorized branch in the shared accept/decline type_check
   (decisions 1–3); everything else untouched.
4. `test/escalation_consumption_test.exs` on the sim world; full suite;
   commit only if green.

## Explicitly deferred

- Re-raising a tender escalation after a declined resolution (R-rail
  policy — one item per tender in v0).
- Authorization consumption for future dispatch acts (4B/4C sim events
  never escalate today; the contract generalizes when one does).
- Deadline expiry semantics on unconsumed approvals (cockpit cadence).
