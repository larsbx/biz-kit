# Hand-off: The D Build — Dispatch on the First Carrier's Exhaust (Coding Agent)

**Gate in — verify before cutting the first phase plan:** a `BuildStarted{section: "D"}`
event exists on the log (the append gate makes it unrepresentable otherwise), which means
`gate(D)` went true on real, consented field data: n_D interviews, corroborated core,
documents, a governance-adopted spec, and a published fixture set. **This brief is written
before that evidence exists, and it knows it**: where this brief and the adopted spec
artifact conflict, the spec governs — it has finding provenance and a signature; this
brief has neither. The first act of every phase plan is transcribing the relevant slice
of the adopted `WorkflowSpecV1` (fetch by the `SpecAdopted` hashes) and flagging every
divergence from the sketches below.

**Scope:** the T0 wedge (corpus 02 §4, 03 §2, HANDOFF §5.4) — back-office automation on
one member carrier's **own exhaust**: tender ingest/parse → envelope-bounded
accept/decline → dispatch → telematics tracking → document parsing → invoice + detention
recovery → dunning. Value at n = 1; κ ≈ 0; the demo kit for the founder campaign
(13 §3) materializes from these folds. It is NOT the Broker Face, not matching across
carriers, not yards, not payments (money stays off-platform — the obligation rail is the
settlement evidence), and not transport connectors (see §2, phase 4D note).

**Read before coding:** the adopted spec + envelope-defaults + fixture artifacts (by
hash, from the log) · `docs/corpus/10_AUTONOMY.md` §0–§5 (the tier doctrine this build
makes real: §4.1–4.2 are the node sketch) · 08 §3 (envelopes/veto/grading), §5 (guards),
§7 (LLM boundary) · 07 §3/§6 (custody pattern, detention) · 00 Art. II (sovereignty —
the hard wall) · `SUBSTRATE.md`, `HARNESS.md`.

---

## 0. Non-negotiable invariants

1. **The carrier's envelope is their signature and their ceiling** (H5; 00 Art. II).
   `EnvelopeDeclared` is member-signed, versioned, atomically revocable (10 P6); the
   envelope defaults from `EnvelopeDefaultsV1` are *proposals* the carrier signs, never
   presets that activate themselves. Out-of-envelope ⇒ a deterministic R escalation
   event — never auto-widen, never auto-act (10 P5). The system may narrow nothing and
   widen nothing.
2. **Every A decision is a pure function of (log, envelope version)** — replay
   reproduces the identical accept/decline/assign/invoice routing (10 P1/P8). Decision
   events carry the envelope version and the decision basis. No clock reads in decision
   logic; event time comes from signed payloads.
3. **Safeguards before autonomy** (10 §3): every externally-visible A act ships
   bounded (in-envelope) + graded (tier demotes on low-grade inputs, never silently
   proceeds) + guarded (v0: override/escalation counters per process — the full
   estimator suite accretes) + **compensable** (a declared compensating event: invoice
   → credit memo; countersign → retraction; anything irreversible-and-unboundable is
   R by H3).
4. **Parses are never authoritative** (08 §7): tender/BOL/POD parsing lands as graded
   verification events carrying the raw-artifact hash (the 2B
   `MachineExtractionRecorded` pattern, production types); self-hosted models first,
   `frontier:` refs still require the dated declaration. **The published fixture set is
   the parser TDD corpus** — that is what the harness was for (11 §1.5).
5. **Money never moves here** (05 P11): invoices and dunning steps are attestations and
   rendered artifacts; settlement evidence is the obligation rail; cash application =
   discharge events. No payment/transfer type may exist — the registry absence test
   already enforces it.
6. **Sovereignty of exhaust**: every stream is the carrier's own (`:bilateral` or
   own-data); nothing crosses to another member. Extend the no-surveillance
   classification map with every new query; aggregates only via the seam.
7. **Check calls are deleted, not automated** (10 §4.1): telematics/status events replace
   the node. Do not build a check-call scheduler.
8. **The demo compiles from full folds** (13 P2): open-book, hours-returned, and
   detention-recovered numbers are pure folds over the carrier's whole stream —
   selective compilation unrepresentable, same recompile-and-compare discipline as the
   process model.

## 1. Counsel gates ([LEGAL] — machinery may exist, use may not)

Dunning-artifact wording per state (collection-practice statutes) — v0 renders drafts the
operator reviews · outbound transmission (email/EDI on the carrier's behalf) — 4D-note
below; nothing transmits in v0 · detention demand letters remain R (H4) always.

## 2. Build phases (each plan transcribes its slice of the adopted spec first)

### Phase 4A — Envelope machinery + the tender rail
`EnvelopeDeclared/Revoked` (member-signed H5; scope `tender_accept`: lanes, rate floor,
equipment, counterparty classes — final field set from the adopted defaults artifact);
`TenderReceived` (raw artifact hash) → `TenderParsed` (graded verification event) →
accept/decline as the pure envelope function → `TenderAccepted`/`TenderDeclined` (with
envelope version + basis) or `EscalationRaised` (out-of-envelope → the R queue seam).
**Acceptance [4A]:** routing replays identically; revocation atomic mid-batch;
out-of-envelope never acts; parser green against the published fixture set; low-grade
parse demotes the decision to R rather than proceeding.

### Phase 4B — Dispatch + tracking
`LoadDispatched` (assignment inside the carrier's own envelope), `StatusRecorded`
(telematics ingest — import-shaped, connector-free), `AppointmentRecorded`,
`LoadArrived/LoadDeparted` (the 07 §3 interchange pattern on the carrier's own stream;
the cross-party yard chain is a later brief). **Acceptance [4B]:** a load's lifecycle is
an unbroken event sequence; dwell is a fold; no check-call machinery exists.

### Phase 4C — Invoice, detention, dunning
`InvoiceIssued` as a **pure function** of custody events + declared terms (the carrier's
rate/free-time declarations — versioned events, not config), detention lines computed
from the arrive/depart-vs-appointment fold with the evidence packet attached by hash
(07 §6: documentation cost to zero, hesitation to zero); `CreditMemoIssued` (the
compensator); `DunningStepped` through declared rungs (A) with `CollectionEscalated`
(R, H4) as the ladder's end; cash application = obligation-rail discharges.
**Acceptance [4C]:** invoice byte-reproducible from the log; detention line carries its
evidence hashes; no dunning step beyond the declared rungs is representable; every
externally-visible act has its compensator.

### Phase 4D — The demo kit + guards v0
Open-book statement, hours-returned, and detention-recovered folds (13 §3 — the founder
campaign's demo assets, live from the hub's real exhaust); stake-view seam = the existing
`Capital` queries; guard counters v0 (escalation rate ε per process, override counts —
10 §5's design lever, surfaced not yet estimated). **Acceptance [4D]:** every demo number
recompiles from the full stream; ε(π) is computable per process; the no-surveillance map
covers every new query.

**Note on connectors (explicitly out):** v0 ingests via manual import (forwarded
mailbox dumps, file drop) and emits rendered artifacts the operator sends. Live
email/EDI/telematics-API connectors are a follow-on brief once the first carrier's real
formats are known — the fixtures will say what to build, which is the harness working
as designed.

## 3. Open questions (owned here until the phase plans take them)

1. Envelope field set and corridor shapes — **decided by the adopted defaults artifact**,
   not here.
2. HOS-feasibility check in the accept function (10 §4.1 names it): v0 data source is the
   carrier's declared driver-hours events vs deferred — spec findings decide.
3. R-queue surfacing: v0 = `EscalationRaised` events + a `mix` listing task; the 10 §5
   cockpit is its own later brief.
4. Rate-confirmation countersign (external-visible, novel-terms → H3): in 4A scope only
   if the adopted spec's findings show carriers want it before invoice value lands.
5. Detention rate/free-time defaults: carrier-declared per counterparty vs single
   declared card — findings decide.

## 4. Deliverables

`docs/phase4{a,b,c,d}_plan.md` per convention (each opening with its spec-slice
transcription); a `DISPATCH.md` normative doc (spec-shape, acceptance mapped to tests);
the suite green with 1A–3B untouched; demo-kit folds consumable by the 13 campaign. The
adopted spec's adversarial cases — the carriers' actual horror stories — must all appear
in the test suite (11 §0: every adversarial case resolves to a reported failure).

**Gate out:** the D slice live on the first hub's books — which is 13 §6's precondition
for the founding-cohort invitation wave. A demo that doesn't run isn't a demo.
