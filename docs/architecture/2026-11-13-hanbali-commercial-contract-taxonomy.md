# Hanbali commercial contracts and Islamic finance candidates for Biz-kit

Date: 2026-11-13. Status: **recorded design specification; contract profiles,
instruments and effectful implementation remain proposed**.

This specification records the researched taxonomy and its application to
Biz-kit's producer cooperative. It identifies recognized contract families,
material differences within Hanbali fiqh, contemporary composites, required
evidence and development priorities. Recording or merging it does not issue
shares, offer finance, establish a scholarly ruling on a completed product, or
authorize a financial or contractual effect.

Primary classical passages and official contemporary resolutions are in the
[source register](2026-11-13-hanbali-contract-sources.md). Source IDs below are
evidence references, not approvals. **MUST**, **MUST NOT** and **SHOULD** express
requirements for future implementations claiming this specification; they do
not describe enforcement already present in the repository.

## 1. Existing decisions and scope

This specification supplements the
[at-cost cooperative ADR](2026-11-07-producer-coop-at-cost-capital-pooling.md)
and [diminishing producer equity design](2026-11-07-diminishing-producer-equity.md).
It preserves their owner decisions:

- Each eligible producer's **$250 annual contribution is intended to acquire
  accumulating, risk-bearing cooperative economic shares**. Legal issuance,
  unit valuation and any separately identified fee component remain to be
  established. The contribution is not a guaranteed redeemable $250 debt.
- Core dispatch, logistics, marketplace, procurement and other cooperative
  services operate at **fully allocated cost**, with supported allocations,
  replacement/risk reserves and cost true-ups. An authorized subsidy must have
  an identified source and cap.
- Annual cooperative capital, optional cooperative investment capital and
  identified project ownership are distinct rights and capital tables. The
  cooperative may itself hold project units; a direct investor's project
  subscription does not become cooperative dues.
- Producer purchases of investors' project units occur as actual cash capacity
  permits, at independently supported contemporaneous fair value. There is no
  promised par redemption or principal-plus-premium buyout.
- Existing business identity, scoped agency and the single authoritative
  ledger/financial-owner boundaries continue to apply.

The main candidates are **agency and service hire for operations; genuine sales
for procurement; co-ownership and carefully scoped partnerships for productive
assets; principal-only loans for separately authorized liquidity; and exact
bilateral setoff for eligible reciprocal debts**. Their priority here is a
product judgment, not a ranking of religious merit.

The implementation boundary follows the
[commercial non-prohibition profile](2026-11-04-commercial-clearing-nonprohibition-profile.md),
[protected admission contract](2026-11-09-commercial-protected-admission.md)
and [discharge decision contract](commercial-discharge-decision-contract.md).
No new ledger writer, transferable network credit or custody capability is
introduced. This documentation milestone does not close source-integrity or
production-activation work, including [#299](https://github.com/larsbx/biz-kit/issues/299).

## 2. Classification method

Classify each arrangement by its **actual legal and economic effect**, then its
selected doctrinal basis. A sale's pricing method, its payment schedule and an
agency mandate are separate dimensions. A cooperative, company or SPV is a
legal wrapper requiring its own analysis; its name does not select a contract.

| Basis label | Meaning in this specification |
| --- | --- |
| **H — classical** | The cited Hanbali text recognizes the contract subject to conditions. This is not a claim that every modern implementation is accepted. |
| **V — selected view** | An intra-Hanbali disagreement materially affects the proposed terms; a specific view and its scope must be recorded. |
| **M — contemporary** | A cited contemporary resolution supports the specified composite or application. IIFA is a cross-school academy, not a substitute for identifying classical Hanbali doctrine. |
| **P — product boundary** | Biz-kit narrows scope or imposes evidence requirements for implementation. Such a restriction is not a universal fiqh prohibition. |

The proposed catalog MUST retain these distinctions per contract/version.
It MUST NOT reduce them to a universal `halal: true` flag. A source-backed
candidate, an adopted doctrinal profile, a civil-law determination and runtime
activation are four separately evidenced decisions.

## 3. Contract taxonomy

### 3.1 Trade, procurement and payment terms

| Candidate | Basis and essential effect | Biz-kit fit and admission condition |
| --- | --- | --- |
| **Musawamah — negotiated sale** (بيع المساومة) | **H**. Sale at an agreed price without representing that price as the seller's original acquisition cost. [H01] | Strong procurement/marketplace candidate where the supplying business sells as principal. Identify goods, seller authority, price and delivery obligations. |
| **Tawliyah — resale at original cost** (بيع التولية) | **H**. A trust-based resale relying on disclosure of the original acquisition price. [H01] | Strong at-cost goods candidate when the asserted cost basis is accurate. Service overhead must not silently be described as original acquisition price. |
| **Murabahah — disclosed cost plus profit** (بيع المرابحة) | **H**, with modern purchase-order applications requiring their own sequence. Known acquisition cost and known profit. [H01], [M02] | Catalog candidate for a separately approved sale business. It does not change the cooperative's chosen at-cost core-service policy. The seller must genuinely acquire the relevant ownership/possession before resale. |
| **Deferred or installment sale** (البيع الآجل / بالتقسيط) | **H/M**. Timing is independent of the pricing method. One price and payment schedule are selected at contract formation; an outstanding debt cannot grow because payment is late. [M01] | Useful supplier credit, including at-cost installments. Preserve the original sale obligation and agreed dates; reject interest-like repricing of an existing balance. |
| **Salam — prepaid specified output** (السلم) | **H** baseline. A sufficiently specified future goods obligation, with the sale capital received in the contract session. [H24] | Later agricultural/production procurement. Record quantity, quality, delivery date/place and qualifying prepayment. A previous unpaid debt is not automatically salam capital. |
| **Urbun — earnest-money sale** (بيع العربون) | **H** with qualifications; **M** supplies the cited modern deadline/application rules. Payment is credited on completion; agreed withdrawal may forfeit it under that profile. [H22], [M08] | Optional reservation-to-sale workflow. Distinguish an actual sale from a request or promise. The IIFA profile excludes salam/sarf and promise-stage murabahah from this treatment. |

Procurement MUST declare whether the cooperative is an **agent buying for a
member** or a **principal buying and reselling**. Mandates, ownership, invoice
parties and compensation must agree with that choice; the system cannot switch
roles merely to produce a desired balance. [H01], [H02]

Fully allocated service cost and tawliyah acquisition cost are different
accounting assertions. Use a disclosed service/agency charge or the appropriate
sale price where needed, with its actual contractual basis. At-cost policies
MUST NOT conceal a markup, and cost recovery MUST NOT be stretched into a
permitted loan benefit merely by placing it on another invoice.

### 3.2 Services, agency and use of productive assets

| Candidate | Basis and essential effect | Biz-kit fit and admission condition |
| --- | --- | --- |
| **Wakalah, including paid agency** (الوكالة بأجر) | **H**. A principal authorizes a defined act; compensation may be agreed. [H02] | First priority for group buying, supplier negotiation and arranging logistics. Record whose account is used, authority limits, conflicts, fee and evidence of execution. |
| **Ijarah of work** (إجارة الأعمال) | **H**. Defined lawful work for known compensation. [H03] | First priority for dispatch, carriage, handling, storage services and administration where the provider undertakes the work. Specify scope, performance evidence and fee basis. |
| **Ijarah of assets** (إجارة الأعيان) | **H**; modern composition has additional conditions. Usufruct is supplied while ownership remains with the lessor. [H03], [M04] | Strong shared-equipment candidate. Identify asset, lawful use, availability, term/rent and maintenance/risk allocation. Rental payments alone do not create ownership units. |
| **Ju'alah — result reward** (الجعالة) | **H**. Known reward for a defined lawful result; effort may be less determinate than in work hire. [H04] | Useful completed-match, recovery or successful-delivery task profiles. Record outcome and completion evidence. A per-job label alone does not establish this classification. |

A dispatch arrangement MUST distinguish an agent arranging a carrier, a
provider owing carriage, a reward for an outcome, and partners jointly
undertaking work. These impose different obligations even when the user sees
the same delivery job.

Asset templates MUST identify ownership-related maintenance and risk, user
operating duties and liability for established misuse. A lease-to-own template
must use the separately reviewed transfer/promise structure described below;
it cannot treat all lease receipts as simultaneous share purchases. [M04]

### 3.3 Ownership and enterprise participation

Hanbali partnership discussions distinguish capital, work and credit-backed
acquisition. The following labels are not interchangeable. [H05]

| Candidate | Basis and essential effect | Biz-kit fit and admission condition |
| --- | --- | --- |
| **Shirkat al-milk — co-ownership** (شركة الأملاك) | **H** ownership relationship, distinct from a mandate to trade for one another. [H05] | Strong foundation for identified equipment and infrastructure. Record actual title/economic rights, fractions, management authority and any separate leases. |
| **Shirkat al-inan — capital partnership** (شركة العنان) | **H**, with **V** for material variants. Known contributions and agreed business activity; profit and ordinary loss have different allocation rules. [H05]–[H07], [H13] | Strong project-equity candidate. Begin with documented cash contributions; asset contributions need an explicitly selected capital-in-kind view. |
| **Mudarabah — capital and management** (المضاربة) | **H**. Capital provider and operator share actual profit; ordinary investment loss falls on capital, with fault liability assessed separately. [H06]–[H08] | Good for a distinct profit-seeking producer project. No fixed return on capital, manager guarantee of ordinary losses, or automatic share of unrelated member revenue. |
| **Shirkat al-abdan — joint work** (شركة الأبدان) | **H**, with **V** for scope variants such as different trades. Partners undertake work and share its earnings. [H09] | Good candidate for a genuine joint producer/transport undertaking. Specify performance responsibility, earnings and the selected view. |
| **Shirkat al-wujuh — credit-based acquisition** (شركة الوجوه) | **H**. Partners acquire goods on credit under defined ownership and liability; ordinary goods loss follows ownership. [H11] | Later joint supplier-credit profile. Identify purchase authority, goods fractions, debtors and exposure limits; no synthetic network purchasing power. |
| **Scoped mufawadah** (شركة المفاوضة) | **H** for a lawful combination of partnership activities. Universal sharing of unrelated gains, liabilities and windfalls is not the accepted form. [H12] | Later composition of explicitly bounded activities. List constituent contracts and liability scopes rather than granting universal mutual liability. |

Profit shares MUST be known fractions of actual distributable profit and obey
the selected partnership's restrictions. They are not arbitrary: work can
justify differences, while a wholly passive contributor's excess share is
restricted in the cited mixed capital/work treatment. Ordinary capital loss
follows capital contributions; wujuh instead follows ownership in the acquired
goods. Proven misconduct, negligence or unauthorized conduct has a separate
liability path. [H06]–[H08], [H11]

Two practical boundaries require explicit selection:

1. **Contributing a truck or inventory for units:** the cited apparent
   cash-capital position and another report permitting goods valued at
   inception differ. Require the adopted view, valuation and actual rights
   transfer before issuing units. [H13]
2. **Investing a receivable:** an existing debt cannot simply be relabeled
   mudarabah capital under the cited baseline. Authorizing collection and
   subsequently investing collected property is a distinct sequence. [H14]

Pooling rentals from separately owned vehicles is not automatically abdan.
The classical transport example distinguishes that arrangement from jointly
undertaking an identified carriage obligation. Keep work earnings, asset rent
and co-owned asset rights separately represented. [H10]

### 3.4 Liquidity, security and guarantees

| Candidate | Basis and essential effect | Biz-kit fit and admission condition |
| --- | --- | --- |
| **Qard — principal-only loan** (القرض) | **H**; **V** for binding maturity. Actual funded principal is owed without a stipulated lender benefit. [H15], [H16] | Separately authorized member liquidity. Record disbursement, principal, repayment and chosen maturity rule; reject interest, rollover increments and conditioned lender gains. |
| **Rahn — collateral** (الرهن) | **H**. Identified property secures an eligible obligation; security does not itself convey investment profits. [H26] | Supporting facility. Record owner, debt, collateral, possession/perfection evidence and enforcement/release terms under the relevant profiles. |
| **Daman — guarantee** (الضمان) | **H**, with **M** guidance on charges. Guarantee liability is distinct from agency or investment ownership. [H18], [M06] | Later supporting instrument. The cited fee profile permits actual administrative expense within its conditions, not remuneration for the guarantee itself. |

The received qard treatment in the cited Hanbali text does not make an agreed
delay binding in the same way as Ibn Taymiyyah's selected binding-term view.
A committed 90-day facility MUST record its choice; storing a due date cannot
resolve this disagreement. [H16]

Loan charges are a separate cost category. Under the cited IIFA resolution,
recoverable loan-service expenses are limited to actual expenses within its
scope. The co-op's wider operating overhead, replacement and risk reserves
are not automatically eligible qard charges. Separate paperwork or a flat fee
does not cure a substantive loan-conditioned benefit. [H15], [M02]

### 3.5 Debt discharge, release and transfer

| Candidate | Basis and essential effect | Biz-kit fit and admission condition |
| --- | --- | --- |
| **Muqassah — setoff** (المقاصة) | **H** for qualifying reciprocal obligations matching the relevant kind, quality and maturity. [H17] | First clearing profile: two business principals, same currency, both obligations presently due, exact current sources and separately evidenced consent. These narrower scope/consent requirements are **P**. |
| **Ibra / sulh — release or settlement** (الإبراء / الصلح) | **H**. An authorized creditor may voluntarily release an identified entitlement; settlement has its own conditions. [H19] | Useful adjustments and negotiated disputes. A coercive haircut of an acknowledged debt is not justified by labeling it sulh. Record scope and actual assent. |
| **Hawalah — debt transfer** (الحوالة) | **H**. Transfers a claim through a qualifying debt relationship with specified conditions. [H18] | Later tripartite profile: identify original debtor, creditor, transferee debtor, underlying debts and the selected discharge/recourse rules. The contract is not synonymous with every modern remittance service. |

The classical matching rule includes relevant same-future-maturity cases;
**both presently due** is this proposed initial product restriction. A owes B
10,000 and B owes A 6,500 in the same currency: a valid setoff of 6,500 in each
direction leaves A owing B 3,500. Correct arithmetic alone establishes neither
the debts nor the discharge. [H17]

Cross-currency debt extinguishment has restrictive and broader Hanbali
analyses. IIFA's settlement-day currency-resolution conditions are also
specific; they do not authorize arbitrary FX or multilateral netting. Keep
the [existing cross-currency preview](2026-11-08-cross-currency-commercial-setoff-preview.md)
inert. Any effectful extension needs a separately selected doctrinal and
activity/jurisdiction profile, valuation/receipt conditions and technical
acceptance. A balanced graph cycle is not itself a hawalah or release. [H25], [M07]

### 3.6 Specialized production and contemporary composites

| Candidate | Basis and essential effect | Biz-kit fit and admission condition |
| --- | --- | --- |
| **Muzara'ah / musaqah** (المزارعة / المساقاة) | **H**, with selected conditions for inputs/work. Farming or orchard work for a known undivided share of actual output. [H20] | Agricultural producer profile. Specify land/trees, work, seeds/inputs and output share. A fixed crop quantity or the produce of an isolated patch is not the same bargain. |
| **Diminishing musharakah** (المشاركة المتناقصة) | **M** composite of genuine partnership/co-ownership and separately completed unit sales. [M03] | Priority project-capital design, subject to implementation gates. Preserve current-value voluntary purchases, genuine ordinary downside and independently attributable project income. |
| **Lease ending in ownership** (الإجارة المنتهية بالتمليك) | **M** with permitted and prohibited structures distinguished. [M04] | Later equipment alternative. Retain a real lease, owner obligations and the approved separate transfer/promise mechanism. |
| **Istisna' — manufacturing order** (الاستصناع) | **M** for the independent modern contract with deferred/milestone payments. Classical Hanbali treatment does not generally admit that whole form independently of qualifying alternatives. [H21], [M05] | Later custom equipment/construction. Select the contemporary profile and define product specifications, price, responsibilities and delivery deadline. Customer-owned materials plus hired work may instead call for service hire. |
| **Waqf — endowment** (الوقف) | **H** for qualifying endowed assets; **V** for a cash-lending endowment. [H23] | Optional mission infrastructure. Endowment assets and beneficiary rights are distinct from redeemable member equity; donor terms and administration need their own record. |
| **Takaful — cooperative protection** (التأمين التعاوني) | **M** for a modern mutual protection arrangement. [M09] | Separate future protection capability. Define fund, participants, contributions, claims, management and surplus rights. An internal reserve is not automatically a takaful operation. |

These are candidate families, not an exhaustive catalog of every Islamic
financial instrument. Unspecified capital products, debt trading, FX execution
or new monetary capabilities are outside this specification's initial scope.

## 4. Cooperative economics and project capital

Core at-cost service collections, capital subscriptions, donations, loan
principal and project profit MUST retain distinct owners, purposes and
accounting treatment. The six accounting categories in the cooperative ADR
remain required. A fee/surplus may enter capital only through an independently
valid and authorized act with identified rights and valuation; historical
payments cannot be silently relabeled equity.

The annual contribution's capital purpose does not itself solve qard's
loan-benefit rule. If capital subscription, a service purchase or a discount is
substantively a condition or consideration for lending, assess that linkage
under the chosen profile. Independence must be real, not inferred from two
documents or from the fee being flat. [H15]

A profit-seeking mudarabah MUST NOT be placed under an absolute requirement
to sell only at cost or below: the cited treatment identifies a defective
condition that prevents its intended profit. Occasional losses and such an
absolute mandate differ. Consequently, cooperative at-cost operations and
project investment mandates need separately identified economics. [H27]

A diminishing project MUST identify actual ownership, permissible project
income, distributable profit calculation, ordinary loss, fault liability,
valuation and separate unit transfers. Lease rent, if used, belongs to a
genuine lease of the relevant ownership interest; it is not automatically
profit of every member business. Unit purchases transfer existing units rather
than issue duplicates. The existing design's current fair-value purchase rule
is the selected product policy within the reviewed composite. [M03]

For each project revision, total held units MUST equal valid issued units.
Distribution rights follow the applicable agreement and period ownership;
no receipt may fund both a project distribution and a cooperative distribution
twice. Governance voting, economic ownership and agent authority remain
separate. These are engineering/accounting requirements in addition to the
contract's doctrinal conditions.

## 5. Proposed versioned contract record

Use the following logical fields when designing future adapters. These are
requirements, **not a new implemented schema or event protocol**. Integrate
with existing canonical IDs, encoding, grants and financial owners.

| Record group | Required content |
| --- | --- |
| Identity and composition | Contract ID/version, family, constituent contracts and dependencies, proposal/effect stage, owning chapter and authoritative system. |
| Parties and capacity | Legal-entity IDs, principal/agent/owner/manager/guarantor roles, current agent identities and grants, exact act, limits and validity/revocation evidence. |
| Subject and consideration | Identified goods/assets/rights or specified future output, title/possession/performance evidence, amount/currency, quantities, dates, conditions and responsible party. |
| Economic terms | Price/rent/reward/fee basis, actual cost evidence when asserted, capital contributions, actual-profit fractions, ordinary-loss rule, fault liability and reserves/true-ups where applicable. |
| Doctrinal profile | Profile ID/version, H/V/M basis, cited source IDs, exact selected opinions and conditions, scope/exclusions, accountable adoption authority, decision date and review triggers. Unselected or unsupported variants remain undetermined. |
| Civil applicability | Existing activity/jurisdiction/facts profile, decision, conditions, effective/expiry dates and accountable review. Religious classification does not imply civil enforceability or licensing status. |
| Commitment and evidence | Exact canonical source identities, revisions and appropriate digest types, operation/request ID, signed terms and independent attestations, snapshot and authority versions, case-scoped evidence references. |
| Lifecycle and accounting | Required acts, effective-date evidence, source consumption/residuals, ownership changes, separately authorized postings, finality/reconciliation if external settlement is required. |

Money MUST use existing exact currency/minor-unit conventions with checked
bounds; avoid floating-point values in commitments. Fractions and valuation
directions must be unambiguous, and rounding/remainders explicitly conserved.
No arithmetic success can authenticate external title, receipt or agency.

Doctrinal profile adoption and civil applicability MUST be separately scoped.
The accepted non-prohibition approach does not require a lawyer to sign every
invoice or a universal legality certificate. It does require the applicable
facts and rules to support an effectful scope. Preserve specialist release
assessments and authority checks where the existing decision contract calls
for them. An unassessed profile remains undetermined.

## 6. Admission, legal effect and replay

The existing V2 admission reserves exact sources and is **inert as to discharge**.
It has operational reservation consequences and is not just a preview. Its
signatures and governance declaration do not constitute later release consent.
The decision prototype's only positive outcome is `validated_inert`: a
historical observation, not executable authority.

| Stage | Required boundary |
| --- | --- |
| Catalog/proposal | May describe a candidate and show inert calculations; no issuance, ownership transfer, discharge or payment instruction. |
| Protected reservation | Follow existing V2 activation, complete source-set commitment and reservation ownership; no implied release or expiry. |
| Evidence/decision | Validate the applicable profiles and exact evidence at a recorded snapshot. Missing, stale, denied or unmet required conditions refuse effectful eligibility. |
| Legal effect | Requires a separately approved effect path, current evidence and the actual legally effective act. A prior inert receipt cannot execute it. |
| Accounting recognition | Requires its own authority and balanced, idempotent recognition tied to legal-effect evidence; projections alone cannot extinguish rights. |
| External settlement | If needed, uses its separate financial owner, authority, provider finality and reconciliation. Clearing does not create a payment writer. |

An adapter MUST preserve the detailed
[discharge decision contract](commercial-discharge-decision-contract.md),
including all of the following:

1. Resolve the complete current reciprocal pair/currency sources from the
   canonical prefix. Bind source order, original/latest event IDs, full-record
   hashes, independently named revisions and precise per-source releases and
   residuals. Equal totals never permit source substitution.
2. Keep full-record hashes distinct from signed-core digests. The V2 and
   complementary lineage projections have different original revision
   baselines; verify them independently, never by adding or subtracting one.
   Require original-attested open lineage; reject assigned/derived/closed or
   inconsistent sources and assignment out-and-back.
3. Independently authenticate both businesses' current agents and their
   purpose-specific consent to the same exact commitment. Historical member
   keys, reservation signatures and governance approval are insufficient.
4. Revalidate ledger/authority fences and serialize any future admitted
   effect with the canonical appender. Reject concurrent double consumption,
   partial writes and changed commitments under a reused request ID.
5. Treat external revocation races explicitly. A status lookup followed by
   compare-and-append does not atomically fence an external issuer. Record the
   observation cutoff; an effectful adapter needs a reviewed fence/lease or
   other solution before claiming current authority.
6. Exact lost-reply retries return the historical committed result. New
   evaluation requires a new request ID and fresh evidence; replay neither
   reauthorizes an old decision nor reruns it against today's conditions.

Keep sensitive documents and adverse findings in restricted case-scoped
evidence storage. Wider views receive only the appropriate minimal result;
neither raw evidence nor guessable document hashes belong in public listings.

## 7. Specification acceptance examples

These examples specify future expected behavior. They are **not claims that
the current runtime executes or verifies these contracts**.

| Case | Expected outcome |
| --- | --- |
| Cooperative buys as disclosed agent within the member's mandate, with an agreed service charge. | Candidate wakalah; verify mandate, cost/fee basis and purchase evidence. |
| A principal promises resale before the required acquisition/possession, while the record says completed murabahah. | Reject the completed-sale classification; preserve the actual request/promise stage. |
| A fixed installment sale price increases after payment becomes late. | Reject that amendment under the stated sale profile. |
| A pre-sale demand deposit is automatically retained as urbun. | Reject that classification without the qualifying sale/profile terms. |
| Two working partners contribute cash 60/40, share actual profit 50/50 and ordinary loss 60/40. | Candidate inan under the selected formulation, subject to the remaining contract conditions. |
| An investor is promised 8% of contributed capital regardless of profit. | Reject that partnership return. |
| A mudarib suffers ordinary market loss without established fault. | Allocate ordinary capital loss to investor capital; do not automatically create manager debt. |
| A manager exceeds authority and causes an established loss. | Determine fault liability separately from ordinary investment loss. |
| A member contributes a truck for units. | Hold pending the capital-in-kind profile, valuation and actual rights transfer. |
| An old invoice is simply renamed mudarabah or salam capital. | Reject automatic conversion; require the valid sequence and qualifying receipt for the selected contract. |
| Separate vehicle owners pool rentals and call it abdan. | Reject that classification; assess the actual leases/ownership/work relationships. |
| Producers jointly undertake specified delivery work and share its earnings. | Candidate abdan with responsibility and earnings terms. |
| A $250 annual contribution is recorded as a guaranteed $250 repayable debt. | Reject the mapping to the existing cooperative capital decision. |
| A loan requires purchasing a lender service, with a flat charge in a separate document. | Do not infer independence; assess the substantive loan-benefit condition. |
| A loan promises binding 90-day maturity. | Require the expressly adopted binding-maturity view and applicable enforceability. |
| Core services stay at cost but investor yield has no identified permissible profit source. | Reject the incomplete economics; do not manufacture distributions from service collections. |
| A mudarabah mandate prohibits every sale above cost. | Flag the defective condition and require a valid redesign. |
| Project investors must be bought out at original principal despite impairment. | Reject under the selected diminishing project profile. |
| A producer voluntarily buys actual units at current supported fair value. | Candidate separate unit sale; verify consideration, title and unit conservation. |
| A owes B 10,000 and B owes A 6,500, same currency, both due. | An authorized qualifying setoff releases 6,500 each and preserves A's 3,500 residual. An inert calculation alone releases nothing. |
| Equal aggregate totals are preserved but a source, creditor or allocation changes. | Reject the prior commitment; require a new authorized evaluation. |
| A source was assigned away and back, an agent was revoked, or the latest source revision changed. | Reject stale protected eligibility under the existing source/authority contract. |
| A cross-currency preview or multilateral graph has balanced totals. | Keep it inert; no inference of discharge, FX authority or hawalah. |
| An old `validated_inert` receipt is supplied to post accounting or settle funds. | Refuse the transition; each effect stage needs its own implemented authority. |
| A manufacturing order uses milestone payments. | Assess the selected contemporary istisna' profile; do not claim the entire structure is the classical Hanbali baseline. |

## 8. Development order and completion gates

| Priority | Candidate work | Completion evidence before effectful use |
| --- | --- | --- |
| **1 — ordinary operations** | Procurement agency, negotiated/at-cost sales, work and equipment hire; result rewards where appropriate. | Defined principal/agent roles, known terms, source/performance evidence, transparent cost policy and integration with existing procurement/dispatch owners. |
| **2 — bilateral discharge** | Same-currency, presently due setoff and explicit releases. | Existing source-integrity/admission program plus adopted contract/release rules, fresh corporate authority, exact consumption, durable retries and approved legal-effect/accounting integration. |
| **3 — cooperative/project capital** | Cooperative unit issuance, cash-funded project ownership/inan, diminishing project shares; separate mudarabah where appropriate. | Legally established instruments, adopted doctrinal profiles, capital tables, title, actual profit/loss attribution, valuation and independent distribution/buyout authority. |
| **4 — optional liquidity** | Funded qard with security where appropriate. | Selected maturity position, loan-benefit and fee controls, underwriting/exposure, actual funding, principal accounting and applicable permissions. |
| **5 — specialized extensions** | Salam, agricultural partnerships, istisna', hawalah, broader partnerships, endowment/protection and effectful cross-currency arrangements. | Separate product evidence, selected opinions, full lifecycle and scoped technical/civil/doctrinal acceptance for each extension. |

For implementation, tests and proofs SHOULD target concrete risks: exact
amount/unit conservation, no duplicate ownership or source consumption,
current scoped authority, role/contract consistency and safe interruption and
retry. Include the negative cases above and meaningful examples of changed
facts. Lean can establish stated mathematical invariants; bounded Quint models
can examine specified schedules; runtime/durable integration tests must show
the implementation preserves those properties. None authenticates external
facts or independently establishes a juristic or civil-law judgment.

This specification is complete as documentation when the taxonomy, doctrinal
choices, source register, existing-policy mapping and acceptance expectations
are recorded and linked. A later implementation PR MUST name the exact profile
and effect stage it enables, identify remaining external dependencies and
provide the evidence appropriate to that change.

[H01]: 2026-11-13-hanbali-contract-sources.md#h01
[H02]: 2026-11-13-hanbali-contract-sources.md#h02
[H03]: 2026-11-13-hanbali-contract-sources.md#h03
[H04]: 2026-11-13-hanbali-contract-sources.md#h04
[H05]: 2026-11-13-hanbali-contract-sources.md#h05
[H06]: 2026-11-13-hanbali-contract-sources.md#h06
[H07]: 2026-11-13-hanbali-contract-sources.md#h07
[H08]: 2026-11-13-hanbali-contract-sources.md#h08
[H09]: 2026-11-13-hanbali-contract-sources.md#h09
[H10]: 2026-11-13-hanbali-contract-sources.md#h10
[H11]: 2026-11-13-hanbali-contract-sources.md#h11
[H12]: 2026-11-13-hanbali-contract-sources.md#h12
[H13]: 2026-11-13-hanbali-contract-sources.md#h13
[H14]: 2026-11-13-hanbali-contract-sources.md#h14
[H15]: 2026-11-13-hanbali-contract-sources.md#h15
[H16]: 2026-11-13-hanbali-contract-sources.md#h16
[H17]: 2026-11-13-hanbali-contract-sources.md#h17
[H18]: 2026-11-13-hanbali-contract-sources.md#h18
[H19]: 2026-11-13-hanbali-contract-sources.md#h19
[H20]: 2026-11-13-hanbali-contract-sources.md#h20
[H21]: 2026-11-13-hanbali-contract-sources.md#h21
[H22]: 2026-11-13-hanbali-contract-sources.md#h22
[H23]: 2026-11-13-hanbali-contract-sources.md#h23
[H24]: 2026-11-13-hanbali-contract-sources.md#h24
[H25]: 2026-11-13-hanbali-contract-sources.md#h25
[H26]: 2026-11-13-hanbali-contract-sources.md#h26
[H27]: 2026-11-13-hanbali-contract-sources.md#h27
[M01]: 2026-11-13-hanbali-contract-sources.md#m01
[M02]: 2026-11-13-hanbali-contract-sources.md#m02
[M03]: 2026-11-13-hanbali-contract-sources.md#m03
[M04]: 2026-11-13-hanbali-contract-sources.md#m04
[M05]: 2026-11-13-hanbali-contract-sources.md#m05
[M06]: 2026-11-13-hanbali-contract-sources.md#m06
[M07]: 2026-11-13-hanbali-contract-sources.md#m07
[M08]: 2026-11-13-hanbali-contract-sources.md#m08
[M09]: 2026-11-13-hanbali-contract-sources.md#m09
