# Phase 8C — Dispatch-D under simulation: invoice, detention, dunning (the 4C slice)

> **Status: COMPLETE** (2026-07-20). Third sim slice under the 8A
> authorization (operator-directed: all three remaining sim slices).
> Acceptance **[8C]** passes: member-signed monotonic versioned terms (1);
> `InvoiceIssued` equal to the gate-recomputed pure function or rejected —
> tampered totals, stale versions, incomplete custody chains all
> unrepresentable, one invoice per load (2); credit memos bounded by the
> invoice with unique memo ids (3); dunning walks the cited version's
> rungs in order exactly once, collection only after the last rung, and
> the ladder is frozen at the invoice's terms version (4); terms/invoice
> streams member-keyed and queries classified (5). Same rules: real
> machinery, untouched gate, nothing simulated is field evidence; the
> real `phase4c` transcribes the real adopted spec.

## Grounding

- `docs/handoff_dispatch_d.md` §2 Phase 4C: `InvoiceIssued` as a **pure
  function** of custody events + declared terms (versioned events, not
  config); detention from the arrive/depart-vs-appointment fold (07 §6:
  documentation cost to zero); `CreditMemoIssued` the compensator (§0.3);
  `DunningStepped` through declared rungs with `CollectionEscalated` (R,
  H4) as the ladder's end; cash application = obligation-rail discharges
  (§0.5: money never moves here — no payment type exists).
- §1 counsel gates: dunning wording is [LEGAL]-gated per state — v0
  renders nothing and transmits nothing; the events are the audit spine
  the operator's reviewed drafts hang off.
- 8A/8B machinery: the accepted tender carries the linehaul rate (graded
  parse); the load fold carries arrive/depart/appointment times.

## Acceptance [8C]

1. **Terms are versioned member-signed events.** `RateTermsDeclared`
   (free-time minutes, detention rate/hour, dunning rungs) follows the 8A
   envelope discipline: member's own current key, strictly monotonic
   versions, exact param set.
2. **The invoice is reproducible or unrepresentable.** `InvoiceIssued`
   must EQUAL `Dispatch.compute_invoice/2` — linehaul from the accepted
   tender's parse, one detention line per stop from
   `max(0, departed − max(arrived, appointment) − free_time)` at the
   declared rate, under the terms version the event cites. A tampered
   total, line, or terms version is rejected before persistence. One
   invoice per load, only after both stops depart.
3. **Every externally-visible act has its compensator.**
   `CreditMemoIssued` reverses invoice value; cumulative memos never
   exceed the invoice.
4. **No dunning step beyond the declared rungs is representable.**
   `DunningStepped` walks the terms' rung list in order, exactly once
   each; `CollectionEscalated` (always R — H4) is representable only after
   the last rung, once.
5. **Classification.** `compute_invoice/2` classified own_data; streams
   member-keyed (departure bundle carries the carrier's invoicing trail).

## Build steps

1. Add this plan and commit before implementation.
2. Registry: `RateTermsDeclared` (member role, `terms/<member>/<entity>`),
   `InvoiceIssued`, `CreditMemoIssued`, `DunningStepped`,
   `CollectionEscalated` (steward role, `invoices/<member>/<entity>`).
3. Projection: `rate_terms` (all versions kept — dunning follows the
   version its invoice cites), `invoices` (total, credited, rungs stepped,
   collection flag); loads gain an `invoiced` marker.
4. `Dispatch.compute_invoice/2` — the pure fold; gate recomputes it on
   `InvoiceIssued` (the 8A decision pattern).
5. Gate checks for acceptance 1–4; no-surveillance entries.
6. `test/dispatch_invoice_test.exs` on the sim world; full suite; commit
   only if green.

## Explicitly deferred

- Evidence-packet-by-hash on detention lines (the gate-recompute makes the
  line's inputs log-derived and tamper-evident in sim; the hash-packet
  format lands with the real 4C spec).
- Rendered invoice/dunning artifacts and any transmission ([LEGAL]; v0 is
  events only).
- Cash application machinery (already exists: the obligation rail; nothing
  new to build).
- Per-counterparty rate cards vs single declared card (spec findings
  decide — brief §3.5).
