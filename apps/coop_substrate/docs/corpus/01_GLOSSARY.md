# 01_GLOSSARY.md — Canonical Terminology

Concern: one name per concept. Each layer document uses its own register internally; this table is the only place mappings live. Rule: outside 00 (jurisprudence-native) and 05 (fiqh contract names as proper nouns), documents use the **system term** column exclusively.

---

## Trust & provenance

| Concept | Jurisprudential | System term (canonical) | Definition | Normative home |
|---|---|---|---|---|
| Chain of transmission | isnād | provenance chain | signed lineage of an artifact/authority to its origin, terminating in a human at privileged boundaries | 08 |
| Chain integrity | ittiṣāl | chain integrity | unbroken, gap-free event chain (custody, delegation) | 08 |
| Conduct axis | ʿadāla | conduct standing | member's behavioral reputation; admission and retention axis | 04 |
| Accuracy axis | ḍabṭ | accuracy grade | correctness of content independent of emitter; graded G0–G3, τ-decayed | 08 |
| Vetting & censure | jarḥ wa-taʿdīl | standing review; censure event / endorsement event | review process adjusting conduct standing | 04 |
| Corroboration breadth | tawātur / mutawātir threshold | corroboration threshold k | independent-attestation floor defeating collusion/Sybil | 08 |
| Sponsored introduction | wāsiṭa | sponsored introduction | edge-owner opt-in referral carrying provenance and reputational exposure | 07 |

## Finance (contract names remain proper nouns in 05)

| Concept | Instrument name | System gloss | Home |
|---|---|---|---|
| Interest-free loan | qarḍ ḥasan | benevolent loan: fixed principal, zero yield, bounded term | 05 |
| Obligation netting | ḥawāla | netting: period-end set-off of like-denominated mutual obligations | 05 |
| Cost-plus resale | murābaḥa | disclosed-markup installment sale; possession-before-resale ordering | 05 |
| Lease / lease-to-own | ijāra / ijāra-to-own | usufruct lease; ownership risk on lessor; title transfer via separate promise | 05 |
| Declining co-ownership | diminishing mushāraka | scheduled unit buy-down at appraisal-current price | 05 |
| Equity partnership | mushāraka | capital partnership; loss strictly ∝ capital | 05 |
| Capital–labor venture | muḍāraba | funder capital + operator labor; declared profit ratio; capital loss on funder | 05 |
| Build-to-spec | istisnaʿ | staged milestone contract | 05 |
| Mutual pool | takāful | donation-funded risk pool with declared management fee and surplus rules | 06 |
| Surety | kafāla | guarantee; no guarantee fee beyond documented expenses | 05 |
| Pledge | rahn | collateral; secured party takes no benefit from the pledged asset | 05 |
| Unilateral promise | waʿd | binding one-sided undertaking, separate from the contract it accompanies | 05 |
| Rotating pool | jamʿiyya (ROSCA) | fixed-contribution deterministic-rotation savings pool | 05 |
| Interest | ribā | prohibited time-value yield | 00 |
| Term uncertainty | gharar | prohibited material ambiguity in contract terms | 00 |
| Stratagem | ḥiyal | formally-valid reconstruction of a forbidden structure | 00 |
| Purification | — | routing of unavoidable credited interest to charity | 05 |
| Zakāt base | zakāt | per-member obligatory-alms base, computed as a log fold | 05 |

## Deontic & authority

| Concept | Jurisprudential | System term | Home |
|---|---|---|---|
| Five-tier lattice | wājib/mandūb/mubāḥ/makrūh/ḥarām | obligatory / recommended / permitted / discouraged / forbidden | 00 |
| Protected objectives | maqāṣid | protected objectives class (forbidden to all capabilities) | 00 |
| Adjudication | tarjīḥ | ruling; contested instruments gated N pending ruling | 09 |
| Privileged direction | — | lax-direction (privileged, human-signed) vs strict-direction (unprivileged) | 08 |
| Autonomy tiers | — | A act · R recommend · N not-yet · block structural | 08 |

## Platform & operations

| Concept | System term (only name) | Home |
|---|---|---|
| Structural enforcement | invalid ⇒ unrepresentable | 08 |
| Declared constants | charter constants: κ, L_max, u_min, u_own, k, τ, m_c, f_c, rate cards, gates, caps | 04 §7 registry |
| Attestation grading | G0 claimed · G1 document-consistent · G2 attested · G3 corroborated (≥k); τ-decay | 08 |
| Asset ladder | prospect → coop_leased → coop_owned ∥ member_owned | 03/07 |
| Coverage predicates | tenderable(carrier) · operable(facility) · dispatchable(service unit) | 06 |
| Custody chain | signed interchange events at every possession boundary | 07 |
| Disclosure classes | commons · telemetry (k-gated) · edges (sovereign) | 07 |
| Clock decoupling | asynchronous staging: yard buffers separating facility clock from carrier clock | 02 |
| Evidence gate | tier-transition predicate evaluated as pure function of the log | 03 |
| Rent-resolution invariant | every captured intermediary margin resolves to declared member-visible splits | 00 Art. IV.4 |
