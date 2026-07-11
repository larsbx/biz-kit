# 04_ENTITIES.md — Organizational Structures & Governance

Register: legal/organizational, system terms (01). Concern: who exists, who owns what, who decides. Constraints: 00 Art. II, IV.

---

## 1. Federation & chapters

```
Federation — standards, protocol, ruling interface (09)
 └─ Chapter (sovereign locality)
     ├─ LandCoop            — land title, member shareholding
     ├─ ServiceCoop         — worker co-op, mobile service
     ├─ Broker Face         — property-broker authority (federation- or chapter-held: OQ1)
     ├─ [Incubator Carrier] — optional, sunset-bound (§6)
     └─ members: carriers, drivers, shops, property-owners, workers
```
Inter-chapter defaults: non-interference; bilateral signed agreements; netting settlement. Cross-chapter shareholding: default no.

## 2. Membership

- Admission: conduct-standing gate (sponsored, reviewed); corroboration threshold k defeats Sybil admission.
- Standing review adjusts conduct standing via endorsement/censure events with provenance; censure is the terminal rung of every default and misconduct ladder.
- Classes: carrier · graduating driver · shop (worker co-op ∨ independent business) · service worker · property-owner · facility worker (pending §7 OQ2).
- One member, one vote in every organ. Economic participation ∝ shares/patronage; governance never.

## 3. LandCoop

- One per chapter; per-parcel LLCs beneath (premises blast-radius isolation).
- Shares: issue/redeem at NAV only, co-op sole counterparty; third-party transfer unrepresentable; concentration ceiling κ; redemption via declared liquidity gates, FIFO queue; exit without forfeiture.
- `NAV(t) = Σ appraised(t) + cash(t) − liabilities(t)`; independent appraisal with provenance; contribution-for-shares at appraisal (second-appraiser protocol on dispute).
- Revenue: staged-capacity fees derived from the custody chain (07); distributions ∝ shares, governance-signed.
- Acquisition finance: closed instrument set in 05 §2; interest-bearing liability unrepresentable.

## 4. ServiceCoop

- Worker co-op; fleet and tooling collectively owned by its worker-members; workforce sovereign (symmetric no-crossover).
- Membership (federation) buys **access + member rate**; service is per-call at the declared rate card; dues ⊥ service revenue — the federation never subsidizes calls.
- Rate card: versioned governance event; off-card invoices unrepresentable; per-call negotiation forbidden; non-members served at market rate, capacity-subordinated; accepted work is never preempted.
- Fleet capital formation: 05 instruments (OQ: benevolent loan vs buy-in vs retained margin).

## 5. Broker Face

Property-broker authority ($75k bond): no motor-carrier operating authority, no carrier safety score, no operational control of power units — while retaining the broker's own bond, payment, carrier-selection, claims-handling, and contractual liability surfaces. Declared defaults for its seven design issues:

| Issue | Default |
|---|---|
| I1 margin disposition | declared split (patronage now / T2 retention), pre-declared decay schedule |
| I2 transparency | open-book to members (owners see the spread); shipper-side confidentiality bilateral |
| I3 allocation | capability + accuracy-grade ranked match with declared fairness-floor weight; sealed bidding excluded |
| I4 non-members | overflow at market with standing membership invitation — the recruitment funnel |
| I5 payment | pay-when-paid at T1; quick-pay T2-gated, funded on the strict receivables set (05 §4) |
| I6 incubator | operate, time-boxed (§6) |
| I7 member freight | voluntary routing; ordinary patronage accrual only; never required, never specifically incentivized |

Uniformity rule: I2/I4/I5 answer one question — *does the Face behave like the brokers it replaces?* — and the answer must be uniformly no; members read any single defection as the whole story.

## 6. Incubator Carrier (optional)

Small carrier authority bridging graduating drivers through the new-entrant mortality valley (years 0–2). Bounded: exit-by-default per driver; chartered with a decay schedule (recommended → discouraged past the graduation window) enforced by a **hard sunset event**, not a norm. Standing risk acknowledged: this is the single largest liability surface on the Face side and the one structural vector toward the rejected single-authority fleet model; 00 Art. II.4 caps it.

## 7. The Operator (single-controller role)

The federation/chapter back office and Broker Face are designed for control by one person (10 §5).

- **Definition**: the Operator is a typed capability set, not a position of trust — sign-authority over the R-queue classes H1 (entity filings), H3 (within governance-approved templates), H4 (claims/escalations), plus veto-window objection rights. H2 remains with governance; H5 with each member; H6 with the ruling organ.
- **Appointment & succession**: governance events; the role is stateless (all decision inputs are folds), so handover is a key ceremony. Temporary delegation (absence) is an attenuated, time-boxed capability grant.
- **Accountability**: every act on-stream and provenance-chained; periodic governance review of the operator's decision log; guards on override and escalation patterns apply to the operator as to any agent. Compensation: fee-for-service ∨ salary declared by governance — never a spread on transactions (rent-resolution invariant applies internally).
- **Budget**: B_op and ε_max(π) are charter constants (§9 registry); sustained budget breach is a design finding escalated to governance, structurally barred from resolving as headcount.

## 8. Open questions

1. Broker Face held at federation vs chapter level (single shipper interface vs locality sovereignty).
2. Facility staffing class for leased docks/warehouses: second worker co-op on the ServiceCoop pattern vs contracted — touches seat-security principles; governance call.
3. ServiceCoop overflow: independent mobile trucks under the card, or exit mobile entirely.
4. ServiceCoop fleet capital formation: benevolent loan vs member buy-in vs retained margin — instrument drafted in 05 once chosen; owned here until then.

## 9. Charter-constant registry (declared before first evaluation; retro-fit void)

κ (share concentration) · L_max (aggregate lease obligations) · u_min, u_own, r_min, d_min (utilization/demand/rent gates) · m₁, e₁ (T1 gate) · m_c, f_c (city activation) · k (corroboration) · τ per entity kind (staleness) · liquidity gates · assessment cap · rate cards · fairness-floor weight · sunset dates · **B_op (operator budget) · ε_max per process (escalation bounds) · δ per veto class · corridor widths & per-period aggregate bounds**.
