# 09_SHARIA_GOVERNANCE.md — Ruling Interface & Compliance Register

Register: jurisprudential where rulings are discussed; system terms for mechanics. Concern: who may settle contested questions, and the standing register of compliance findings. Authority: 00 Art. I.2.

---

## 1. The ruling interface

The corpus encodes rulings as validation predicates but needs an organ empowered to issue them. Interface (specified now; organ composition is a governance decision):

```
RulingIssued {instrument | practice, verdict ∈ {permitted, conditioned(preds), forbidden},
              basis, provenance chain, scope(chapter | federation), review_date?}
RulingSuperseded {ref, replacement}
```
- Contested instruments are gated **N** — unrepresentable in live use — until a ruling event exists; a ruling's conditions compile to validation predicates (08 §2).
- Organ options: external qualified board · qualified member committee · per-chapter with federation appeal. Default recommendation: federation-level board with chapter application; adjudication authority is a single choke-point with provenance, like every other authority in the system.
- Divergent-school questions: ruling records the position adopted and the divergence — members deserve to know where reasonable scholars differ.

## 2. Findings register (from AUDIT-1; status tracked here henceforth)

| # | Finding | Severity | Disposition | Owner doc |
|---|---|---|---|---|
| F1 | Captive reserve investment unspecified ⇒ interest by default | 🔴 | remediated: treasury whitelist, off-whitelist unrepresentable | 05 §6, 06 §1 |
| F2 | Conventional fronting/reinsurance — bounded-necessity posture needs demonstrable exit | 🟡 | remediated in structure: captive as mutual pool from day one; mutual reinsurance preference documented; ruling on residual conventional shell pending | 06 §1 |
| F3 | Paid-collection + loan on same receivable = stratagem for discount factoring | 🔴 | remediated: strict receivables set; paid-collection variants gated N | 05 §1.3 |
| F4 | Declining co-ownership buy-down at origination-fixed price ≈ capital guarantee | 🟡 | conditioned: appraisal-current unit pricing; fixed-price variant gated N | 05 §1.1 |
| F5 | Lease-to-own validity conditions unstated | 🟡 | remediated: risk-allocation, promise-separation, abatement predicates | 05 §1.1 |
| F6 | Cost-plus resale: possession ordering; arrears handling | 🟢 | encoded: event-ordering constraint; charity-penalty option | 05 P2, §5 |
| F7 | Surety fees | 🟢 | encoded: ≤ documented expenses, structural | 05 §3 |
| F8 | Netting denomination mixing | 🟢 | encoded: like-for-like constraint | 05 P5 |
| F9 | Fee-for-service layer (dues, cards, slot fees) | 🟢 | clean | 04 §4 |
| F10 | LandCoop shares/NAV/gates | 🟢 | clean; contribution-dispute protocol before first contribution | 04 §3 |
| F11 | Zakāt ungoverned | ⚪ | remediated: per-member fold | 05 §7 |
| F12 | Idle cash across all entities ⇒ interest by default | 🔴 default | remediated: treasury policy + purification transfers | 05 §6 |
| F13 | Rotating pools — minority reservation | 🟢 | permitted per majority; divergence noted in instrument | 05 §1.2 |
| F14 | No adjudication organ | ⚪ | interface specified (§1); organ composition open | this doc |

## 3. Standing obligations

- Every new instrument or practice enters at N unless it composes entirely from already-ruled primitives.
- The audit re-runs on corpus change affecting Article III surfaces; findings append to §2, never overwrite.
- Annual review of bounded-necessity items (F2 residual, frontier-model usage): necessity must remain demonstrable and minimized, or the permission lapses.

## 4. Caveat

This register and its dispositions are structural compliance work, not fatāwā. Every 🟡 marks genuine scholarly divergence requiring an authoritative ruling through §1 — which is precisely why the interface is the register's first section.

## 5. Open
1. Organ composition and appointment (04 governance).
2. Review cadence and quorum for rulings.
3. Whether chapter-scoped rulings may diverge (school-plurality across localities) or federation rulings bind uniformly.
