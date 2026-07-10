# Phase 1C — Throughput/floor compute + privacy seams

> **Status: PLANNED** (2026-07-10). Scope is the hand-off's Phase 1C (§2.4–2.5, §4);
> acceptance = hand-off §6 items **[1C] 12–14**. Gate honored: 1B passed in full
> (SUBSTRATE.md §12) before this was cut.

## Grounding — the corpus is now available

Unlike the 1A/1B plans, this plan is grounded in the **normative corpus** at
`tmp/freight_coop_corpus/corpus/` (untracked; `HANDOFF.md` REVISION-2 is its index), primarily:

- **08_PLATFORM** — privacy mechanism ladder (§6: *minimum necessary mechanism* — plain
  signatures → k-anonymity → additive HE → ZK → nullifiers; escalate only on demonstrated
  failure; "premature cryptographic overbuild is itself a defect", §9), verification doctrine
  (§9: replay-checkable P-properties + adversarial suite), coordination rails (§8).
- **05_FINANCE** — the obligation-relationship rail (§1.2: obligations, assignments,
  discharges as typed dual-signed events; **money movement stays off-platform** — P11 no
  platform custody [LEGAL: money-transmission boundary]); netting as a *computation over the
  rail* (P5 like-for-like); P10 (netting/exposure/ledger computations are pure log functions).
- **11_HARNESS** — gates *workflow* builds (D/L/Y), *not* the substrate: per HANDOFF §5 the
  Envelope substrate is itself the phase gate, so no interviews are prerequisite here. What
  does bind is the **spec-shape rule** (HANDOFF §6): build-facing work ships a §0 spine,
  P-properties, and an adversarial suite — this plan and the SUBSTRATE.md §13 it produces do.

`throughput_and_floor.md` (the hand-off's cited spec for §2.4) remains **absent** — the
component taxonomy and floor formula below come from the hand-off text plus corpus
disciplines (constants declared before first evaluation, 00 Art. IV.2; pure folds; in-log
versioning per the 1B accrual-rule pattern). Flagged, not reconstructed from memory.

## §0 Spine

```
throughput(member, entity, window, as_of) = fold(rule_vN, component events ≤ as_of within window)
cleared?(member, window)                  = throughput(...) ≥ threshold_vN(class)   — the floor
aggregate(chapter, metric)                = Privacy.Aggregate.sum(contributions)    — seam, not sum
settlement evidence                       = discharge events on the obligation rail — never funds
```
Everything is a pure function of (log, in-log rule version); no wall-clock reads — windows
evaluate against a caller-supplied `as_of` and event `timestamp_ms`.

## Settled decisions

- **Reuse the 1B in-log versioning pattern wholesale.** `ThroughputRuleActivated{rule_id,
  params}` and `FloorRuleActivated{rule_id, params}` mirror `AccrualRuleActivated`: pure rule
  modules in code registries, params validated at the gate, forward-only activation, every
  evaluation records the rule it ran under. No shared "generic rule framework" — three small
  parallel registries beat one abstraction nothing else needs yet.
- **Throughput components — one claim-shaped event, closed component set.**
  `ThroughputRecorded{member_id, entity_id, component, units, occurred_ms, source_ref?}` with
  `component ∈ Constants.throughput_components()` (`delivery`, `match`, `custody`,
  `labor_hour` — PLACEHOLDER set, awaiting the missing spec / charter). Gate: active
  membership, known component, positive units. This is the **G0-claim carrier** (08 §4): when
  real custody/delivery streams exist (dispatch phase), components derive from those events
  and this type is demoted — the fold's input seam is the component taxonomy, not this type.
- **Settlement component comes from the obligation rail, not a claim event** (05 §1.2). Three
  new types, all money-off-platform (05 P11):
  - `ObligationRecorded{obligation_id, debtor_id, creditor_id, amount_minor, denomination}` —
    dual-signed (`debtor` + `creditor` roles; both must be registered members signing with
    their current keys — the 1B key-authenticity check reused).
  - `ObligationAssigned{obligation_id, new_debtor_id}` — debtor substitution (ḥawāla
    assignment); signed by outgoing + incoming debtor. **FLAGGED PLACEHOLDER**: whether the
    creditor must co-sign is governance semantics (1D), as signer roles were in 1B.
  - `ObligationDischarged{obligation_id}` — dual-signed attestation that settlement happened
    *externally*. Discharges are the verified `settlement` throughput component.
  Gate: parties registered; obligation exists, open, not already discharged; positive amount;
  assignment only on open obligations. **The platform never represents fund movement** —
  there is no payment/custody event type to misuse (invalid ⇒ unrepresentable, 08 §2).
- **Netting is a query, not an event** (v0): `Finance.netting(chapter, pair)` computes
  period-end set-off over open obligations **within one denomination** (05 P5), pure
  read-side. A `NettingExecuted` event (batch discharge) is deferred until the settlement
  workflow exists — flagged.
- **Floor = threshold predicate + cure/hardship lifecycle states** (hand-off §2.4; the 1B
  lifecycle left the seam: `MembershipFloorExited.evaluation_ref`). Lifecycle additions —
  exhaustive, property-test extended:

  | Event | From | To |
  |---|---|---|
  | `FloorCureStarted` | `member` | `in_cure` |
  | `FloorCureCleared` | `in_cure` | `member` |
  | `HardshipDeclared` | `member` | `hardship` |
  | `HardshipEnded` | `hardship` | `member` |
  | `MembershipFloorExited` | `member`, **`in_cure`** | `floor_exited` |
  | `MembershipDeparted` / `MembershipDeceased` | + `in_cure`, `hardship` | (as in 1B) |

  `in_cure` and `hardship` stay **active** for patronage/throughput accrual (PLACEHOLDER
  governance semantics, like probationary in 1B). `hardship` suspends floor evaluation.
  `Floor.cleared?(gate-like fold, member, entity, as_of)` is a pure query;
  `FloorEvaluationRecorded{member_id, entity_id, cleared, rule_id, window_ms, value}` is
  **representable** (steward-signed) so floor-exit provenance has something to reference —
  but the gate does **not** yet require it on `MembershipFloorExited`, and no automation
  emits it (that is workflow, 1D-shaped; same posture as 1B redemption enforcement).
- **Anti-gaming logic accretes later, but the data doesn't foreclose it** (hand-off §2.4):
  no circular-netting detection or per-counterparty caps in v0. What ships now is only what's
  expensive to retrofit: `ThroughputRecorded.source_ref` (hash pointer to future evidence)
  and the obligation rail's explicit counterparties (caps become a fold the day a constant is
  declared). A raw counterparty field on the *claim* event is deliberately **omitted** —
  counterparty identity is sovereign edge data (07 §5); how caps see counterparties without
  disclosing edges is an 08 §6 ladder decision, flagged open.
- **Privacy interfaces (hand-off §4), sized by the corpus ladder (08 §6).** Two behaviours +
  a seam stub, backing selected by app config, callers import the interface only:
  - `Privacy.Aggregate` — `sum(contributions) → total`. Day-one backing: plaintext fold. A
    second backing (`Aggregate.Opaque`, a trivially-different stub) exists **only in test**
    to prove acceptance 13: swapping backings changes zero caller code.
  - `Privacy.Proof` — `prove(fact, inputs) → proof` / `verify(fact, proof) → bool`. Day-one
    backing: trusted-but-auditable — recomputes the fact from the log and returns a signed
    assertion carrying the fold inputs' hash. Used by nothing critical yet; the seam is the
    deliverable. First real facts: `floor_cleared`, `balance_at_least`.
  - `Privacy.JointCompute` — behaviour stub only (hand-off: "not needed for substrate;
    define the seam").
  Per 08 §6 and §9, **no HE/ZK/enclave code in 1C** — plain rung until a rung demonstrably
  fails. All cross-member summation routes through `Aggregate` (system throughput per
  chapter, sinking-fund totals); a member's **own-data** reads (their account, their
  throughput) stay direct — no privacy boundary is crossed reading your own fold.
- **No-surveillance is tested as an absence** (hand-off invariant 6, acceptance 14): every
  public query function on `Capital`, `Throughput`, `Floor`, `Finance`, and the aggregate
  API is enumerated in one test and classified `own_data | aggregate | system`; an
  unclassified public function fails the test, and no classified path accepts
  (requesting-member ≠ subject-member) for `own_data`. The substrate has no authn layer yet,
  so v0 pins the *shape*: query modules take an explicit `for_member:` context and the test
  asserts the classification — enforcement middleware is 1D.
- **Disclosure classes get real values** (07 §5 via the registry's existing
  `disclosure_class` field): obligation-rail events are `:bilateral` (new class — the 08 §6
  default rung), `ThroughputRecorded`/`FloorEvaluationRecorded` are `:telemetry`-classed.
  v0 enforces nothing on the classes (streams are chapter-internal); the k-gate arrives with
  publication features. Representable now, enforced later — flagged.

## Build steps (TDD — tests with/before each module)

1. **Plan doc** (this file) — commit.
2. **Lifecycle extension** — `in_cure`/`hardship` states + five transitions; extend the
   exhaustive matrix property test; `active?/1` covers the new states (PLACEHOLDER-flagged).
3. **Type registry + constants** — nine new types (`ThroughputRecorded`,
   `ThroughputRuleActivated`, `FloorRuleActivated`, `FloorEvaluationRecorded`, four lifecycle
   events, `ObligationRecorded`/`ObligationAssigned`/`ObligationDischarged`);
   `Constants.throughput_components/0`, `:bilateral` disclosure class.
4. **Gate checks** (`Protocol.Validity` + gate-state additions in `Projections.Membership`
   or a sibling fold) — component known, units positive, active membership; rule activations
   validate params; obligation existence/open/dual-registration/current-key checks;
   discharge-once; assignment-on-open.
5. **Throughput engine** — `Throughput.Rule` behaviour, `Rules.WeightedSumV1` (PLACEHOLDER
   formula: `Σ units × weight_bp(component) / 10_000`), registry,
   `Projections.Throughput` fold (per (chapter, member, entity), entries record `rule_id`),
   `Throughput.value/5` with `window:`/`as_of:`. Tests: purity (replay twice ⇒ identical),
   rule change forward-only (as-of byte-stable across activation), window edges, discharge
   events counted as `settlement`.
6. **Floor** — `Floor.Rule` behaviour, `Rules.ThresholdV1` (PLACEHOLDER: per-class
   `threshold_minor`, `window_ms`), `Floor.cleared?/4`; hardship suspension; evaluation-event
   representability; `in_cure`→`floor_exited`/`member` paths over the real log.
7. **Obligation rail + netting** — `Projections.Obligations` fold (open/assigned/discharged
   per chapter); `Finance.netting/2` pure pairwise like-denomination set-off (05 P5) with a
   property test (netting never crosses denominations; set-off ≤ min of mutual sums).
8. **Privacy seams** — `Privacy.Aggregate`/`Privacy.Proof`/`Privacy.JointCompute` behaviours;
   plaintext + trusted-but-auditable backings; config-driven selection; aggregate queries
   (chapter system throughput, sinking-fund total) routed through `Aggregate`. **Seam-swap
   test**: run the same aggregate assertions under both backings with zero caller changes
   (acceptance 13).
9. **No-surveillance test** — the classification-enumeration test over the whole public
   query surface (acceptance 14).
10. **SUBSTRATE.md §13–§14** — normative write-up (spec-shape: spine, P-properties below,
    adversarial results), placeholder table updates, §8 open-question updates; README/quickstart
    status lines — commit.

## Properties (replay-checkable; the §13 suite enforces these)

```
P1  throughput and floor are pure functions of (log ≤ as_of, in-log rule version):
    replay ⇒ identical; rule activation is forward-only (prior as-of values byte-stable)
P2  every throughput entry and floor evaluation records the rule_id it ran under
P3  all thresholds/weights/windows arrive via *RuleActivated params — none hardcoded
P4  lifecycle matrix (9 states incl. nil × 12 events) remains exhaustive: undeclared pairs
    rejected at the gate, pre-persistence, chains verifying after
P5  obligation lifecycle: recorded ≺ (assigned)* ≺ discharged, each dual-signed with the
    parties' current keys; double-discharge and orphan assignment unrepresentable
P6  no event type represents platform fund movement (05 P11): settlement is attestation only
P7  netting is computed within a single denomination (05 P5) and is a pure log function (P10)
P8  swapping the Aggregate backing changes zero lines in capital/throughput/floor/finance code
P9  every public query function is classified own_data | aggregate | system; own_data paths
    are keyed by the requesting member; no path returns one member's detail to another
```

## Adversarial suite (seeded per 08 §9)

Self-crediting throughput inflation (units on a departed membership → gate-rejected) ·
discharge replay / double-discharge · assignment after discharge · cross-denomination netting
attempt · rule-params smuggling a hardcoded-constant bypass (activation params validated) ·
floor evaluation against a stale rule (evaluation records rule_id; mismatch detectable on
replay) · aggregate query leaking a single contributor (n=1 aggregate — **flagged**: the
k-gate is the declared upgrade, 08 §6; v0 documents rather than blocks) · own-data query for
another member_id.

## Explicitly deferred (flagged, not forgotten)

- Anti-gaming graph checks: circular/self-dealing netting detection, per-counterparty caps —
  and the privacy-preserving counterparty tag they need (08 §6 ladder decision).
- `FloorEvaluationRecorded` required on `MembershipFloorExited`; automated evaluation cadence
  (workflow, 1D-shaped). Cure-window duration: charter constant, undeclared.
- `NettingExecuted` (batch discharge) event; exposure caps (05 P7) as gate checks.
- k-anonymity gate on `:telemetry` publication; any HE/ZK rung (escalation requires a
  demonstrated failure of the plain rung, 08 §6).
- [LEGAL] money-transmission boundary of the obligation rail (HANDOFF §4 counsel gate) —
  representability now; external use waits on counsel.

## Acceptance / verification (hand-off §6 [1C] items 12–14)

- **12** `mix test` green incl.: throughput/floor purity + forward-only versioning (P1–P3);
  extended lifecycle matrix (P4); obligation rail properties (P5–P7).
- **13** seam-swap test passes under both `Aggregate` backings with zero caller diffs (P8).
- **14** no-surveillance classification test passes; absence tested, not asserted (P9).
- `cargo test` still green (1C adds types, not encoding — no canonical-profile change).
- 1A/1B suites untouched and green.

**Gate:** nothing from 1D starts until the above pass.
