# Producer capital integration against the current Biz-kit contract taxonomy

Date: 2026-11-13. Status: **source-reviewed specification + inert Elixir
previews only**. This ADR does not register an event type, alter a ledger,
issue shares or admit financial contracts.

This integrates the [producer-owned cooperative](2026-11-07-producer-coop-at-cost-capital-pooling.md)
and [diminishing producer asset partnership](2026-11-07-diminishing-producer-equity.md)
with the source-backed [2026-11-13 Hanbali taxonomy](2026-11-13-hanbali-commercial-contract-taxonomy.md)
(PR #393), the existing [producer capital proof bank](../../proof_bank/producer_capital/README.md),
[procurement host](2026-11-08-procurement-mvp-host.md), open
[inert procurement classification PR #395](https://github.com/larsbx/biz-kit/pull/395),
[commercial discharge boundary](commercial-discharge-decision-contract.md),
[protected commercial admission](2026-11-09-commercial-protected-admission.md)
(merged PR #351), merged
[source-pinned SCF correspondence PR #389](https://github.com/larsbx/biz-kit/pull/389)
and open follow-on [SCF PRs #387/#391](https://github.com/larsbx/biz-kit/pull/391).

## 1. Authority, economic purpose, and what is NOT interchangeable

| Rights / transaction | Product decision | Contract candidate and required distinct evidence | Current implementation |
| --- | --- | --- | --- |
| Annual member capital participation | Each eligible producer contributes **USD 250 per year**, intended to accumulate cooperative economic units. No fixed return or par redemption. | Adopted cooperative legal instrument, capital/fee allocation, NAV-priced issue terms, verified member authority and receipt. **Not** a `PatronageRecorded` event or an ordinary refundable debt. | **Pure annual-contribution candidate only; no units issued.** |
| Cooperative operational services | Dispatch, logistics, marketplace, group procurement and goods at **fully allocated cost**, with real allocation/true-up. | Wakalah where buying as an agent; tawliyah only if the original acquisition-cost representation is true; musawamah for negotiated principal sale; ijarah of work/asset for real services/use. [H01–H03] | Procurement host has bounded request/quote/dispatch receipts; open PR #395 proposes a separately inert classification review. No project-capital writer. |
| Pooled member investment | Separate from required annual contribution and voting. | Legally constituted capital class, cash subscriptions and adopted doctrinal/civil profile. No automatic reclassification of old fees or invoices. | **Not issued.** |
| Project-specific productive assets | Producer, cooperative pool and opt-in businesses hold **distinct asset/project serials**. | Shirkat al-milk title; selected inan profile for actual capital partnership; optional mudarabah must be explicitly separate. Cash funding and title required; contributing a truck for capital requires a selected capital-in-kind view [H05–H08, H13]. | Lean/Quint **abstract model only**, plus read-only snapshot shape validation here. |
| Gradual producer buyout | An operating producer voluntarily buys named investor units **at independently supportable then-current valuation**, from existing owners; investor accepts impairment. | Diminishing musharakah [M03], with **separate real unit sales**, identified current seller, producer, title, currency, exact serials, consideration, appraisal, consent and completion. | **Read-only, caller-asserted transfer candidate**; no commit. |
| Profits and losses | Investors share true project performance, not hidden markup on at-cost services; ordinary capital losses must be borne as agreed/legally required. | Known actual-profit fractions, ordinary capital loss rules, misconduct liability separate [H06–H08]. Mudarabah cannot be required to sell all goods at cost or below [H27]. | Formal proof-bank has abstract observed earnings/loss/distribution transitions, not operative postings. |
| Separate interest-free liquidity | Optional principal-only qard, never automatically funded from the share ledger. | Funded qard, chosen maturity view, no stipulated lender benefit or hidden fees [H15–H16, M02]. | **Not implemented** by this PR. |

**No blanket compliance claim.** The Hanbali source register documents classical
versus selected opinions and modern composites. A legally operative arrangement
requires adoption of a specific profile, independent civil regulatory scope,
evidence of actual facts and the signed effect path. Recording references is
not clerical adoption, a Shariah ruling, securities clearance or title transfer.

### Existing capital-account name collision

`CoopSubstrate.Capital` and `Projections.CapitalAccounts` currently
represent *historical patronage accrual/redemption* over
`PatronageRecorded`, `AccrualRuleActivated`, and related legacy events.
Its `credited_minor - redeemed_minor` arithmetic and some terminal-state
`redeemable` statuses do **NOT** represent new cooperative economic equity,
NAV, current asset title or a promised redemption of the annual $250.
Do not reinterpret the existing projection or migrate previous entitlements
without independently authorized historical classification and reconciliation.
The new proposed `ProducerCapital` rights must use separately versioned
event contracts and maintain dual-rail read separation until independently
reconciled.

## 2. First compatibility slice (no effects)

`CoopSubstrate.ProducerCapitalPreview` exposes:

- `annual_contribution/1`: strict USD 250/year capital-class **candidate**.
  Explicitly issues *zero* units and returns HOLD for legal issuance and NAV.
- `buyout/3`: versioned exact serial cap-table source shape, producer-only
  acquisition from current nonproducer shareholder, same-currency integer
  per-unit appraisal, source revision, quote expiry and distinct consent and
  consideration references. Preview serials move to the producer without
  changing total issued units or implying financial/title effects.
- A canonical **length-prefixed SHA-256 proposal commitment** that binds
  input cap-table, revision, chosen doctrinal/civil source refs, specific
  serials, current per-unit consideration, appraisal, approvals, and receipt
  *identifiers*. This is **not a signature or trusted provenance digest**.

The pure helper accepts **host-asserted** company IDs, appraisal references,
consent references and title evidence. It cannot establish their truth, signer
authority, legal sufficiency, regulatory compliance or currency settlement.
It checks integer and serial conservation only for the supplied snapshot.
It has no writer, network call, money movement, corporate onboarding, payment,
capital allocation, lease or investment sales endpoint.

The initial project profile is explicitly
`diminishing_musharakah_asset_coownership`, backed by actual co-ownership,
a capital-proportionate ordinary-loss rule, and **zero guaranteed capital or
fixed return**. Mudarabah, financial loans, cash-funded subscriptions and
project distributions require **different** effect profiles; none are quietly
accepted through this one.

## 3. Conformance to the existing formal bank

`proof_bank/producer_capital` already contains a Lean functional transition
system, universal safety theorems, a bounded Quint monitor and mutant checks.
It separates `CoopClass.membership` versus `optionalInvestment`,
per-project serials, exact quote/transaction binding, independent observer,
revocation, retained project earnings, cash and reserves, and source/tx
replay. The older proof bank is **not a runtime implementation**, and no
machine-checked refinement relation connects it to the Elixir preview.

| Formal model requirement | This PR's bounded pure acceptance | Missing effectful refinement |
| --- | --- | --- |
| One holder per issued serial | Exact 0..N-1 partition; no duplicate units; transfer never mints | Durable ownership, genuine legal title, independent company identities |
| Producer buys another holder's units | Nonproducer seller, exact serial subset and producer-only buyer | Current legally verified buyer/seller grants, independent signatures |
| Current price and revision | Valid term revision, positive exact per-unit amount, quote valid at supplied `now` | Trusted independent appraiser, real clock, revoked appraisal and authenticated evidence |
| Repeated use of economic source | Next pure snapshot refuses already-moved serials | **Not protected:** durable source/tx ID fence, races, restart, forged same-source instruments |
| Realized profit/loss | Not modeled by this helper; formal kernel has conditional properties | Actual finance/asset evidence, selected profit fractions, liability, balance-sheet posting |
| Solvent, lawful distributions | Always absent from previews | Signed current legal rights, restrictions, liquidity, loss/credit/solvency clearance |
| Cooperative vs project balances | Annual unit issuance explicitly blocked; no project write | New authoritative share-class source, separate issuer, reconciliation and governance |

Do not relabel `CoopSubstrate.ProjectOwnership`: it is **TaskCore
accountable owner backfill**, not equity title. Merged SCF PR #389
provides a **bounded source-pinned runtime observation and Lean correspondence
gate for selected list/entry operations**; its formal registry still records
`refinement_claimed: false`. Draft #387 and #391 carry additional abstract
SCF and statement obligations. None establishes producer-project ownership,
cooperative NAV issuance, or a capital-event-to-SCF general posting adapter.

## 4. Integration with current operations and source-bound contract work

- **Demand-first P0**: existing procurement host continues buyer wanted
  request → seller quote → signed acceptance → merchant fulfillment. No
  project capital prerequisite, tax-sale status or execution endpoint.
  Open PR #395 proposes signed review of wakalah/musawamah/tawliyah against
  current business orders, with both doctrinal and civil decisions still
  undetermined. Our capital preview does not share or supersede those
  procurement classification permissions.
- **At-cost services**: wakalah/ijarah/tawliyah distinctions from PR #393
  must be selected per exact contract, and fully allocated service cost
  never silently becomes asserted original acquisition cost.
- **Capital project P1/P2**: distinct approved issuer for every economic
  class and asset project, signed current business/agent authority,
  independently attested title and cash contributions, a complete price
  and revision commitment, durable unit/source fences and appropriate
  approvals. Separate project board authority from member organization
  voting and from direct investor economic rights.
- **No cross-domain writer**: capital units are not the native Hawala
  balance or `NettingExecuted` obligation. Merged #351 adds an **opt-in
  chapter-wide protected admission profile** that refuses legacy aggregate
  `NettingExecuted` and other direct source mutations once activated; it
  does not retroactively secure unactivated chapters or establish legal
  discharge. P0 #299 and the separate discharge-decision work remain open.
  A business receipt cannot certify external money settlement.
- **Accounting**: real investment purchase, disposal, impairment, profit,
  distribution and capital-class movements need separate authorized
  balanced postings, ideally through the appropriate SCF host where it
  applies, with an independent source-to-runtime refinement gate.

## 5. Exact acceptance / activation blockers

1. Actual legal cooperative instrument, membership/economic-unit class,
   approved NAV or unit pricing, rights/voting, admission and redemption.
2. Identified issuer and asset/project title, active legal businesses,
   rights/restrictions, independent appraiser, project funds and operator
   profit/loss records. Define the accepted selected Hanbali opinion where
   capital-in-kind or unusual profit shares are proposed.
3. Source commitment over authentic original signed records, all signers'
   current corporate grants and title/evidence; compare-and-append under
   a single local canonical authority. Refuse stale, revoked, substituted,
   overlapping, duplicate, and replayed unit sales after restart.
4. Contractually effective transfer and *separate* accounting/financial
   operations with independent evidence, permitted jurisdiction and
   securities/lending/foreign-investment analysis. Legal and doctrinal
   profile admission decisions must be separately versioned.
5. Profit/loss distribution and revaluation tests for stale/excess cash,
   reserves, a loss, insolvency, fixed returns, director conflicts and
   independent co-op voting.
6. At least two independently operated hosts, explicit partitions,
   reversed messages, refusal and reconciliation; no implicit global
   ACID or regulator-approved status.

No capital project, member subscription, investment advertisement, actual
unit transfer, custody, loan, dividend or redemption is authorized by the
pure contract acceptance. CI must not be described as legal approval.
