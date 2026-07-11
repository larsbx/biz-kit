# 10_AUTONOMY.md — The Sign-Off Boundary & Autonomous Workflow Architecture

Register: engineering/system terms (01). Concern: the exhaustive closed set of acts requiring human signature, and the promotion of everything else to autonomous execution. Mechanisms imported from 08 §3 (envelopes, veto windows, grade-conditioned tiers). Process grounding: T0–T1 research (order-to-cash, detention, insurance, compliance, facility intel, brokerage, group purchasing, backhaul, payment/factoring).

---

## 0. Spine rule

```
R(act) ⇔ act ∈ H          — H is a CLOSED set, enumerated in §2
A(act) ⇐ act ∉ H ∧ envelope(act) ∧ safeguards(act)
block  ⇐ act ∉ H ∧ ¬classifiable   — unclassified acts fail closed, never default to A
```
The human signs **policies, envelopes, attestations, and governance** — never routine transactions. Fear is not a gate criterion; where the historical reason for human review is error-risk or liability-anxiety, the replacement is structural (bounds, grades, guards, compensation, replay), not a click. A click that reviews nothing protects no one and costs the member the hours the system exists to return.

## 1. Sign-off necessity predicate

```
H(act) ⇔ statutory_attestation(act)                                    — H1
        ∨ charter_or_governance_event(act)                              — H2
        ∨ (external_commitment(act) ∧ ¬∃ envelope ⊇ act)                — H3
        ∨ claim_or_legal_escalation(act)                                — H4
        ∨ envelope_declaration(act)                                     — H5
        ∨ ruling(act)                                                   — H6
```
Nothing else. An act failing all six disjuncts and still routed to a human is a design defect, logged as such.

## 2. The H-set, exhaustive

### H1 — Statutory personal attestation (law demands a natural person's warranty)
| Act | Cadence | Note |
|---|---|---|
| Insurance application / renewal submission | annual | warranty of accuracy; misrepresentation voids coverage — packet A-assembled from whitelisted graded fields, one signature |
| Sworn claim documents, proof of loss | per claim | |
| Tax & regulatory attestations: IFTA quarterly, IRP, UCR, MCS-150 biennial, drug-consortium enrollment | periodic | **veto-window eligible** under standing POA where jurisdiction permits — computation A, notification T, execution T+δ; taxpayer responsibility remains and is disclosed |
| Driver-qualification and employment certifications | per hire | carrier-sovereign act regardless |

### H2 — Charter & governance events (constitutional, 00 Art. IV)
Charter constants and amendments · rate cards · admissions and expulsions (conduct-standing judgment) · distributions and assessments · lease/acquisition/charter executions · sunset declarations · margin-split ratios. Periodic by nature; never per-transaction.

### H3 — Unbounded external commitments (no envelope can contain them)
Novel-terms contracts (head leases, fronting agreements, program contracts, POAs themselves) · **new-counterparty credit establishment** (a shipper/broker credit line is signed once; all subsequent transactions within the line are A) · any instrument creating fixed liability (feeds L_max).

### H4 — Claims & legal escalation
Insurance claim *filing* (file/no-file is an economic judgment with experience-rating consequences) · formal legal demands, collections escalation, litigation · dispute responses with admission risk. Note the boundary: an **invoice** — including a detention line item on attested evidence at declared terms — is not a demand; it is A (§4).

### H5 — Envelope declarations (the member's own autonomy policy)
Each member/entity signs its envelopes: tender auto-accept policy (lanes, rate floors, equipment, counterparty classes) · quoting corridors · dunning ladder consent · POA grants · introduction policies. Sovereignty is *expressed as* the envelope: the carrier decides its own autonomy level; the system never decides it for them, and never requires more clicking than the member chose.

### H6 — Rulings (09 §1)
Per contested instrument, once; conditions compile to predicates thereafter.

## 3. Safeguards that replace review (all four required for externally-visible A acts)

```
bounded        act ∈ human-signed envelope; out-of-envelope ⇒ R escalation, deterministic
graded         tier(act) = f(min grade(inputs)); low-grade inputs demote, never silently proceed
guarded        estimator guards watch the AGENT (error rate, override rate, escalation rate) —
               chronic overrides/escalations are structural signals on the classification itself
compensable    ∀ externally-visible A act: declared compensating action (credit memo, retraction
               event, corrected filing) with its own tier; irreversible ∧ unboundable ⇒ ∈ H3
```
Plus universal: replay-determinism (every A decision is a pure function of log + envelope version) and atomic revocation of envelopes.

## 4. Process autonomy matrices (T0–T1; DAG nodes → tier)

### 4.1 Order-to-cash (carrier back-office)
| Node | Tier | Bound |
|---|---|---|
| Tender ingest, parse, grade | A | grade-conditioned |
| Accept/decline tender | **A** in envelope (lanes, floor, counterparty class, HOS-feasibility check) | H5 policy; out-of-envelope → R |
| Rate-confirmation countersign | **A** in envelope | same envelope; novel terms → R (H3) |
| Dispatch, driver assignment | A | carrier's own envelope |
| Status: check calls **eliminated** — telematics events replace them | A | the node is deleted, not automated |
| Document collection (BOL/POD parse → graded events) | A | parses are graded verification events, never authoritative (08 §7) |
| Invoice issuance (incl. accessorial lines) | A | derived from custody chain + declared terms; pure function |
| Dunning ladder | A through declared rungs | escalation to collections/legal → R (H4) |
| Cash application, netting | A | 05 |

### 4.2 Detention & accessorial recovery
Evidence fold (arrive/depart vs appointment) A → packet assembly A → **detention invoice line A** (attested evidence, declared free-time/rate terms, counterparty within credit line) → payment follow-up A per ladder → *formal claim or demand letter* R (H4). The industry's unbilled-detention leak is a documentation-and-timidity failure; the fold removes documentation cost to zero and the envelope removes the per-invoice hesitation.

### 4.3 Insurance lifecycle
Certificate issuance/verification A (deterministic derivation; grades) · coverage monitoring + capability revocation A (obligatory, fail-closed) · renewal packet A-assembled → submission **R** (H1) · endorsements: draft A; submission **A when derived wholly from ≥G2 events** (VIN from parsed title, driver from DQ events) under broker-of-record standing authorization, else R · claims: notice packet A (deadline obligatory), filing R (H4).

### 4.4 Compliance administration
IFTA: fuel/mileage folds A → return computed A → **veto-window filing** (H1 note) · IRP/UCR renewals: same pattern · HOS/ELD recordkeeping, DQ-file completeness sentinels, audit-packet assembly A · drug-consortium enrollment R (H1), random-selection compliance monitoring A.

### 4.5 Facility intelligence
Entirely A: ingestion, folds, k-gated publication, staleness sweeps (07 §5). Zero human nodes.

### 4.6 Brokerage operations (the Face)
| Node | Tier | Bound |
|---|---|---|
| Shipper quote | **A** within pricing corridor | corridor = H2 governance constant; outside → R |
| New shipper credit line | R once (H3) | thereafter tenders within line A |
| Carrier sourcing/vetting | A | grades + coverage predicates, imported |
| Rate negotiation | A within corridor | counter outside corridor → R |
| Tender, tracking, docs, shipper invoice, carrier payment | A | custody chain; declared terms; netting/quick-pay per 05 |
| Margin split accrual | A | declared ratio (H2) |
| Open-book member reporting | A | pure fold |

### 4.7 Group purchasing
Program contract R once (H3) · enrollment of members A (eligibility = membership fold) · per-transaction discounts, rebate reconciliation, spread audit A.

### 4.8 Backhaul matching
Lane-graph folds, candidate ranking, offer dispatch A · acceptance = carrier's own envelope (H5) · sponsored introduction requires edge-owner signature — but the edge-owner may envelope *that* too (standing introduction policy per counterparty class): sovereignty includes the right to automate one's own consent.

### 4.9 Payment & quick-pay
Invoice verification A (custody-chain resolution) · nullifier publication A (structural) · quick-pay advance within program terms + per-borrower caps A · program terms and funder participation agreements R (H3) · default ladder: cure/notification A → surety call A per instrument terms → pledge liquidation **R** (irreversibility) → censure event A.

## 5. The single-operator bound

Design target: the entire back office and brokerage controllable by **one person**. Formalized:

```
B_op declared (charter constant, hours/period)
∀ period p: Σ_{act ∈ Rqueue(p)} cost(act) ≤ B_op          — operator-budget invariant
∀ process π: ε(π) = escalations(π)/acts(π) ≤ ε_max(π)      — escalation-rate bound
∀ item ∈ Rqueue: decision_ready(item)                       — packet-completeness predicate
```

**Load model.** `L = λ_H1·periodic + λ_H2·governance + λ_H3·new_counterparties + λ_H4·incidents + ε·volume`. The first four terms are per-entity/per-event, not per-transaction — they don't scale with freight volume. The fifth is the only volume-coupled term, and ε is a **design lever**: corridor widths, envelope coverage, and grade floors tune it. A process whose ε stays high under tuning is misclassified (10 §1) — redesign, don't staff. Member-side H5 envelopes are each member's own signature and never enter the operator's queue.

**Decision-ready discipline.** The operator never assembles, only judges and signs. Every R item arrives as: packet (folds, grades, provenance) + recommendation + bounds + compensation path + deadline. Items missing any element are returned to the emitting agent as defects, not worked. Deadline-aware ordering (claim-notice deadlines are obligatory); batch signing where law permits (endorsement batches, filing batches under one attestation where the jurisdiction allows).

**The cockpit** (all derived, zero private state):
```
R-queue          decision-ready items, deadline-ordered
guard board      estimator alarms incl. agent-watching guards (ε per process, override rates)
envelope registry versions, coverage maps, escalation heat per envelope → widen ∨ fix
veto feed        pending T+δ executions with one-tap objection
fold health      staleness, grade-decay, replication lag
```

**Control ≠ impunity.** One person in *control* does not weaken verification: the verifier is the system — structural predicates, replay audits, guards — plus periodic governance review of the operator's fully on-stream, provenance-chained acts. Proposer/verifier independence (08 §3) holds because the operator only ever signs what agents propose against predicates the operator cannot alter unilaterally (charter constants are governance-signed). Protected-objectives class remains unreachable by the operator as by anyone.

**The role is stateless.** Every input to every operator decision is a fold over the log plus envelope versions; no knowledge lives in the person. Consequences: succession = governance appointment event + key ceremony, not knowledge transfer; vacation coverage = temporary capability grant; the bus factor of the back office is the bus factor of the log — which replicates. Key custody per 08 §9: role key, rotated, governance-recoverable; no long-term single-operator-key dependence.

## 6. Properties

```
P1  ∀ A act: resolvable to (envelope_version, human_sig) ∨ act is strict-direction internal
P2  H-classification is total and closed: unclassified external acts ⇒ block (fail-closed)
P3  ∀ veto-window act: notification event ≺ execution by ≥ δ(class); objection ⇒ halt, deterministic
P4  ∀ externally-visible A act: compensating action declared with tier ≤ original
P5  out-of-envelope escalation is deterministic and logged; silent widening unrepresentable
P6  envelope revocation atomic: no act at t > revocation(t) under the revoked version
P7  agent-watching guards active per §3; chronic escalation/override emits structural finding
P8  ∀ tier assignment: replay of (log, envelopes) reproduces the identical A/R routing
P9  Σ cost(Rqueue(p)) ≤ B_op; breach emits a structural design finding, never a staffing action
P10 ∀ R item: decision_ready(item); incomplete items return to emitter as defects
P11 operator decisions are pure functions of (log, envelopes, packet) — the role is stateless
P12 ∀ operator act: on-stream, provenance-chained, governance-reviewable; none reaches the
    protected-objectives class
```
Adversarial: envelope-boundary probing (acts split to fit corridors — aggregate-per-period bounds close this), stale-envelope execution post-revocation, veto-notification suppression, grade inflation to promote tier (attestation forgery → censure + demotion), compensation-path abuse as free option, **queue flooding to manufacture time pressure on the operator** (rate-limited per emitter; deadline forgery unrepresentable — deadlines derive from log events) — fail closed or detected.

## 7. Open

1. δ per veto class; POA validity per jurisdiction (counsel-gated, per state).
2. Corridor widths and per-period aggregate bounds — H2 constants; interaction with I3 fairness floor.
3. Endorsement-submission grade floor (≥G2 proposed) — confirm with fronting counterparty.
4. Envelope UX: default envelopes at onboarding (conservative) vs opt-in per policy — adoption vs safety trade, member-sovereign either way.
