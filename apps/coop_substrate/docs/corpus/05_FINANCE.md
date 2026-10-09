# 05_FINANCE.md — Instruments & Treasury

Register: finance; instrument proper nouns retained (glossed in 01). Concern: every way money moves or sits. Constraints: 00 Art. III. Discipline: every instrument is a typed event; the sets below are **closed** — a structure outside them is unrepresentable, not merely prohibited.

---

## 1. Instrument sets by need

### 1.1 Asset acquisition (member-to-member and co-op)
| Instrument | Mechanics | Validity predicates (structural) |
|---|---|---|
| Diminishing mushāraka | co-ownership; scheduled **unit-quantity** buy-down; usage rent ∝ remaining shares | unit *price* = appraisal-current at each purchase (fixed-at-origination price gated N pending ruling, 09/F4) |
| Murābaḥa | funder acquires, resells at disclosed fixed markup, installments | possession-before-resale event ordering; no compounding; arrears → charity-penalty only (§5) |
| Ijāra / ijāra-to-own | usufruct lease ± title transfer at term | ownership risk & major maintenance on lessor; transfer via separate unilateral promise; rent abates on destruction (F5) |
| Istisnaʿ | build-to-spec, staged milestone payments | milestones gate payments; amendments append-only |

### 1.2 Liquidity
- **Netting first** (ḥawāla): period-end set-off of like-denominated mutual obligations; like-for-like constraint structural. Cheapest capital is capital never moved.
- **The obligation-relationship rail** (restored primitive): ḥawāla proper is a *witnessed transaction-relationship facility, not settlement* — obligations, assignments (debtor substitution), and discharges are typed, dual-signed, witness-attestable events on the log. **Money movement stays off-platform**: members settle externally and attest discharge; the platform never takes custody of funds, holding the money-transmission boundary [LEGAL]. Netting is a computation over this rail; settlement is evidence about it.
- **Qarḍ ḥasan**: fixed principal, zero yield, bounded term; cost recovery ≤ documented administration.
- **Jamʿiyya (ROSCA)**: fixed contribution, deterministic rotation — pure function of the log; minority scholarly reservation noted (09/F13).

### 1.3 Receivables — the strict set
Discount factoring and its reconstructions are excluded (09/F3: loan-plus-service to the same counterparty is a stratagem).
1. Qarḍ ḥasan secured by pledge of the receivable + surety; zero yield.
2. Murābaḥa expense substitution: fund the expense at markup, not the invoice.
3. Paid-collection variants: gated N pending ruling.
**Double-pledge prevention**: pledging a receivable publishes a nullifier; a second pledge of the same receivable is unrepresentable network-wide, rates undisclosed (08 §6).

### 1.4 Venture
- **Muḍāraba**: funder capital + operator labor; profit per declared ratio; capital loss on funder absent negligence. Native to carrier-sponsored graduation.
- **Mushāraka**: joint capital; loss strictly ∝ capital.

## 2. Co-op acquisition finance (LandCoop)
Ordered: share capital → in-kind contribution at appraisal → diminishing mushāraka → murābaḥa → ijāra-to-own → qarḍ ḥasan bridge (timing only). Mortgage debt and any time-value-accruing liability: unrepresentable.

## 3. Credit substrate (cross-cutting)
- Underwriting = the trust layer: conduct standing is the credit check; accuracy-grade history is the performance record.
- **Surety (kafāla)**: voucher's guarantee with real exposure; no guarantee fee beyond documented expenses (structural).
- **Pledge (rahn)**: available on asset-backed instruments; secured party takes no benefit from the pledged asset; custody chain supplies attested collateral condition.
- **Default ladder**: cure window → surety performs → pledge liquidates → censure event. Never penalty interest.
- **Exposure caps**: per-funder concentration and per-borrower aggregate across instruments — declared, structural; chapter-level total M2M exposure visible only as a privacy-preserving aggregate (08 §6).

## 4. Quick-pay (Broker Face I5)
Pay-when-paid at T1. Quick-pay is a T2-gated feature: float supplied through §1.3's strict set by member-funders; the Face's yield structure is fee-for-service, never a discount on debt. Nullifier applies.

## 5. Arrears & penalties
No time-value accrual anywhere. Optional deterrent: declared fixed penalty routed **entirely to the chapter charity account** (never to the creditor); compensation limited to actual, provable cost. Late payment additionally emits a standing-review input.

## 6. Treasury policy (all entities: federation, chapters, LandCoop, ServiceCoop, captive, smoothing funds)
- Placement whitelist: ṣukūk, screened equity (business-activity + financial-ratio screens as validation predicates), murābaḥa/wakāla placements with Islamic treasuries, non-interest cash. Off-whitelist placement events unrepresentable (09/F1, F12).
- Non-interest accounts where available; any unavoidable credited interest emits a purification transfer to charity — never revenue, never netted against fees.

## 7. Zakāt
Per-member base computed as a pure fold over classified events (asset-class treatment: rental real estate on net income; trade assets on corpus; shares on the underlying). A-tier computation; member-sovereign disclosure — their fold, their data. Cheapest high-value feature in the corpus.

## 8. Properties
```
P1  every instrument event ∈ closed sets above; disguised-yield structures are type errors
P2  murābaḥa: acquisition ≺ resale in event order
P3  lease instruments satisfy F5 predicates (risk allocation, promise separation, abatement)
P4  surety fee ≤ documented expenses; pledge yields no benefit to secured party
P5  netting only within identical denomination class
P6  nullifier uniqueness per receivable, network-wide
P7  exposure ≤ declared caps, per-funder and per-borrower
P8  no representable time-value-accruing liability on any stream
P9  treasury placements ∈ whitelist; credited interest ⇒ purification transfer
P10 zakāt, netting, exposure, and ledger computations are pure functions of the log
P11 no platform custody of member funds: only obligation/assignment/discharge events are
    representable; settlement is external, attested, never executed by the platform
```
Adversarial: markup restructured as time-accrual; linked loan+service; nullifier evasion via invoice splitting; straw-member cap bypass (corroboration threshold defends); side-letter obligations (void — only on-stream obligations are enforceable).
