# Commercial clearing: scoped non-prohibition profile

Date: 2026-11-04. Status: **accepted product boundary; jurisdictional classification not yet established**.
Owner: Biz-kit commercial/barter capability. Relates to [commercial clearing ADR](2026-11-03-ledger-first-commercial-clearing.md), audit #290 and source-integrity issue #299.

## Decision

The acceptance question for a narrowly specified activity is **whether the actual conduct is prohibited or requires a regulatory license/permission not held by the operator**. We do not require a universal proof that every commercial transaction is "lawful", a general compliance certificate, or an outside lawyer's signature on every invoice.

This is a **non-prohibition determination with defined assumptions**, not a declarative legal exemption. It cannot be asserted until the actual jurisdictions, operators, execution paths and applicable rules are documented and examined. A change to those facts invalidates the previous determination.

A commercial proposal, contractual discharge and external financial settlement are three different outputs with separate authorities. An inert proposal may be shown without establishing that a debt was legally extinguished. An event that actually closes the debt must have source-authenticity, proper signers, agreed setoff/release terms and durable admission evidence; code cannot create a contractual release merely by labeling a state `cleared`.

## Narrow initial operating profile: B2B bilateral business obligations

Only the following profile is eligible for a non-prohibition assessment:

- Parties are two separately identified businesses acting as principals on their **own**, authentic, existing reciprocal receivables/payables. Natural persons may act only through authenticated, currently scoped business agency.
- Each obligation is source-owned, identifiable, revision-bound, denominated in the **same** currency, and acknowledged by its debtor and creditor. No cross-currency conversion or automatic third-party transfer.
- The platform offers read-only accounting, matching and unsigned proposals. Any actual bilateral discharge requires independently evidenced agreement and authorization by both businesses, without implied consent.
- Each party retains its business-accounting authority. No platform custody, platform receipt/transmission of value, pooled customer monetary balances, transferable trade credits, redeemable network units, unilateral third-party payouts, remittance orders, or standalone financial settlement writer.
- Residual payments, if any, are performed by each payer via separately approved bank/provider arrangements. The commercial clearing system neither holds balances nor instructs payment on the payer's behalf.
- The pilot is limited to jurisdictions **actually assessed**. Domestic-only is a profile constraint, **not** an automatic exemption. International, three-or-more-party netting, assignment chains, crypto settlement, FX and transferable credit require separate legal and technical profiles.

The platform shall not claim this profile from a marketing name such as "barter", "commercial clearing", "noncustodial" or "hawala". Assess observable operations, including the platform's ability to direct value, the actual legal entities, contractual rights and economic effects.

## Minimal applicability record (per product profile and jurisdiction)

Store the following as durable review evidence; do not demand a fresh outside legal opinion per invoice:

| Field | Required evidence |
| --- | --- |
| `profile_id`, `profile_version`, `facts_hash` | Exact capability set, deployment, actor/beneficiary roles, business flows and permissions |
| `jurisdictions` | Operator and relevant merchant locations, applicable state/federal/foreign law, choice-of-law limitations |
| `activity_assessment` | Review of money transmission/value substitutes, stored value/credits, payment processing, sanctions, licensing and any other triggered sector-specific rules |
| `authorities` | Primary statutes/regulations/guidance, authoritative URLs, effective dates and specific factual mapping; absence of a rule in one jurisdiction is not a license in another |
| `decision` | `not_prohibited_for_scoped_mode`, `prohibited` or `undetermined`; distinguish a genuinely applicable exemption from an activity outside a definition |
| `scope_conditions` | Facts essential to the conclusion, missing data, permitted operations, forbidden capability transitions, expiration/review triggers |
| `review` | Named accountable reviewer/decision authority, date, evidence version, changes and re-review disposition |

**Default is `undetermined`.** `not_prohibited_for_scoped_mode` is permitted only when supported by a positive applicability analysis of all relevant requirements within that *specified* scope; it never means "legal everywhere." A review is not conclusive where the operator's activities are unclear, sanctions scope is unchecked or an applicable licensing question is outstanding.

Do not infer a blanket exemption from the lack of platform fiat custody: the U.S. definition expressly reaches acceptance and transmission of **other value that substitutes for currency**. Nor should the system claim the BSA-regulated-institutions-only clearinghouse exclusion for merchants merely because their provider uses banks.

## Rules and supporting authorities (reference, not a favorable classification)

1. **31 CFR 1010.100(ff)(5)** — federal money transmitter definitions, facts-and-circumstances application, limited exclusions. https://www.ecfr.gov/current/title-31/subtitle-B/chapter-X/part-1010/subpart-A/section-1010.100
2. **FinCEN MSB interpretation** — activity facts determine classification; an arrangement's name is insufficient. https://www.fincen.gov/resources/statutes-regulations/administrative-rulings/application-money-services-business-2
3. **OFAC FAQ 9** — sanctions restrictions can cover debt, goods and contingent property interests even without a bank transfer. https://ofac.treasury.gov/faqs/9
4. **State supervision is separate** — state money transmission law is not automatically displaced by federal definitions; adoption and interpretation differ. https://www.csbs.org/csbs-money-transmission-modernization-act-mtma

These are **screening starting points**; they do not resolve relevant state rules, commercial debt/setoff law, contractual enforceability, taxes, insolvency or foreign obligations. An appropriate legal reviewer may be needed for disputed or material questions, but not as a per-transaction approval ritual.

## Machine-checkable boundaries and negative controls

The source-binding and admission program in issue #299 remains a **ledger-integrity** requirement for an event that changes books, not a proof of legality. Technical acceptance should verify:

1. A `proposal` remains unsigned, non-admitted, non-discharge and non-settlement, with no platform custody, payment instruction, FX, transferable balance or new financial writer.
2. A purported `discharged` event requires a complete canonical original-source ID/revision/hash set, separate current-key consents, business agency claims, the applicable agreement, and the existing serialized business-log admission. Duplicate source claims, altered same-total obligations and competing writers must fail.
3. Eligibility for an activated profile is lost when a controlling fact, jurisdiction, agency grant, policy decision or capability changes. `undetermined` and `prohibited` fail closed for irreversible external effects; an inert proposal can instead return HOLD for review.
4. No historical `NettingExecuted` signature is reinterpreted as binding exact source IDs. The stricter source-bound profile must refuse legacy aggregate-only admission while preserving historical replay.
5. Tests of a legal profile verify that the software **stays within its assumed fact pattern**. They cannot independently prove any external fact or the correctness of the legal classification.

## Acceptance and release discipline

- **Documentation milestone:** the profile and applicability record exist; this does **not** grant production permission, change any ledger write path, or close audit #290 or P0 issue #299.
- **Inert pilot:** allow accounting and unsigned proposal previews, explicitly labeling any classification as `undetermined` until independently grounded.
- **Bilateral admission:** require source-specific authorization, mutual agreed contractual effect and serializable no-double-discharge, with any legally triggered registration/authorization in place before activation.
- **Expanded profiles:** evaluate multilateral assignment/novation, cross-border reciprocal delivery, provider flows, crypto and transferable credits separately before any such operation is offered.

This decision supersedes broader language in prior planning drafts that could be read as requiring a universal proof of lawful discharge or individual counsel approval on every invoice. It **does not** waive actually applicable legal, sanctions, licensing or source-accounting requirements.
