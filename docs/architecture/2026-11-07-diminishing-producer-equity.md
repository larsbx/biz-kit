# Producer capital shares and diminishing productive-asset co-ownership (proposal)

Date: 2026-11-07. **Business mechanism specified by user; legal instruments, accounting,
Shariah conformity, investment eligibility and valuation procedures NOT approved.**
Companion to [cooperative operating/capital ADR](2026-11-07-producer-coop-at-cost-capital-pooling.md),
[member capital issue #328](https://github.com/larsbx/biz-kit/issues/328) and
[market viability issue #308](https://github.com/larsbx/biz-kit/issues/308).

## Substantive decision

This is a **producer-owned mutual-support and investment network**, not a
commission-maximizing marketplace or a lender seeking a fixed return.

1. Eligible business producers acquire **accumulating economic cooperative
   shares** through their **$250 yearly membership contribution**. They may
   separately subscribe additional member investment capital. The unit
   price / annual contribution allocation, rights, voting and impairment
   must be established by charter, audited NAV and applicable law; a $250
   contribution is **not** a guaranteed redeemable $250 debt.
2. Shared marketplace access, dispatch, logistics, group procurement and
   other cooperative services are provided at **fully allocated cost**,
   with appropriate cost true-up and reserves. These services are not
   quietly marked up to generate investor yield.
3. Producers may co-own identifiable infrastructure and business equipment
   with **a pooled cooperative investment fund and/or independently admitted
   opt-in capital providers**. Each project maintains a **separate**
   ownership/economic-rights table. A subscription to an individual project
   is not the same security/economic right as owning shares in the parent
   cooperative.
4. The operating producer **progressively buys investor asset/project
   shares at independently agreed, contemporaneous fair value**, as actual
   cash capacity permits. Shares acquired transfer productive title/economic
   rights; the producer's ownership increases while investor ownership
   decreases. A pre-agreed price of original principal plus a premium,
   unconditional par-value repurchase, guaranteed return or interest-like
   payoff is outside this program.
5. Project investors receive variable, contract-defined share of **actual
   net commercial project profits**, and accept genuine ordinary downside
   through shared asset impairment and loss. Profit share and loss
   distribution must be legally specified. A modeled default is
   proportional profit/loss to current equity; other schemes require
   a separately reviewed agreement.
6. The goal is **mutual producer profitability**, productive capacity
   accumulation, genuine risk-bearing project returns, and lower-cost access.
   The cooperative does not automatically own a percentage of all revenue
   from members' unrelated businesses. Participation must be voluntary,
   rights explicit, risk disclosed and annual exit/redemption governed.

This resembles a **diminishing equity partnership** (diminishing
*mushārakah*) but resemblance is **not** a Shariah compliance certificate.
See the International Islamic Fiqh Academy's resolution
[No. 136 (2/15)](https://iifa-aifi.org/en/33542.html), which distinguishes
genuine profit-and-loss exposure, separate staged purchases at market/agreed
sale-date value, and impermissible guarantees of initial subscribed capital.

## Three capital tables, three authorities

| Asset/right | Issuer/legal owner | Accounting / consequences |
| --- | --- | --- |
| Cooperative economic membership units | Producer cooperative | Yearly $250 contribution buys legally issued NAV-priced units; exposure to pooled capital gains/losses; governance rights separately chartered |
| Optional cooperative member investment units | Producer cooperative or approved separate capital vehicle | Additional risk-bearing capital class, admission/limits/tax/security terms independently approved; must not silently multiply voting control |
| Project-specific equipment or producer-enterprise units | Named asset company / project consortium or asset-title trustee | Every investor and the operating producer owns stated units; current-unit profit claims, actual asset risk and specifically documented voluntary buyouts |

The pooled cooperative may itself be one investor on a project cap table.
Direct project investors' cash is **not** recorded as the cooperative's dues
or capital pool unless the legal documents actually make it so. Producer
ownership represents real capital or property; do not book phantom equity.
A direct investor does not obtain governance authority over the entire co-op
solely by owning a project's asset.

One member / one vote independent of capital units is a **recommended
cooperative governance default**, subject to entity law and bylaws—not a
claim that economic ownership automatically grants one vote per unit.

## Canonical asset investment events and checks (not implemented)

An approved system should have **one authoritative legal/cap-table owner**
for each asset project (which may be a producer-controlled entity,
cooperative SPV or independently constituted partnership). Biz-kit can keep
approved business evidence projections and reconciliation; neither a
federated advertisement nor a host-provided JSON claim transfers title.

- `ProjectProposed`: producer, identified asset(s), total cost, estimated
  useful life, maintenance/custody, external commercial thesis,
  governing jurisdictions, liquidation ranking, financial projections.
- `ProjectSubscriptionApproved`: investor current eligibility and authority,
  signed risk disclosure, capital amount, unit price, entity right, limit.
- `AssetAcquiredAndTitleVerified`: paid seller, serial/title, asset custodian,
  source invoice; book fair appraisal and actual ownership issuance.
- `OperationalProfitMeasured`: independently sourced **net** external
  commercial revenues less project-level direct/overhead/insurance/tax and
  equipment costs, using approved allocation policy, not co-op service
  markups. Negative values reduce equity or consume properly attributed
  reserves rather than creating negative interest.
- `ProjectDistributionApproved`: if profits actually realized and reserves,
  liabilities and solvency permit, allocate the approved earnings to current
  economic-right holders under signed agreement, no fixed return.
- `AssetRevaluedOrImpaired`: independent valuation method, market price
  evidence, loss, depreciation and insurance, with correction/revision.
- `ProducerUnitPurchaseProposed`: seller investor, producer, precise units,
  **current independently supportable valuation** and buyer funds;
  conditional offer, not compulsory fixed principal repurchase.
- `UnitsSoldAndConsiderationVerified`: independently confirmed real payment
  or legally effective barter, asset/equity title transfer, current owner
  approvals, immutable source-unit debit and matching buyer-unit credit.
- `ExitOrLossRealized`: sale/loss evidence, asset liquidation priority,
  eventual final project NAV and actual investor profit/loss reports.

For any project and every accepted revision:
`producer_units + pooled_coop_units + direct_investor_units = issued_units`.
Buying a share is **not** generating new shares; it transfers from owner to
buyer, and cash flows in the opposite direction. Every dividend relates to
earned, allocated distributable profits and current rights, not principal.
Project and cooperative ledgers must never pay from the same receipt twice.
Cross-party settlement needs independent authority, durable idempotency,
source-bound evidence, and no automatic cross-node ACID assumptions.

## Illustrative agreement economics, NOT a target return

A $100k project is initially 60% cooperative-pool financed, 20% directly
financed by a separate investor and 20% producer-owned. If a period produces
**$20k genuinely distributable commercial profit**, a simple pro-rata
agreement yields $12k to pooled investors, $4k to the direct investor and
$4k to the producer.

Suppose the equipment is then appraised at **$90k** because of wear/market
change. The producer may voluntarily buy **$10k of outstanding investor
equity at the actual $90k appraisal**; this purchases 11.111... percentage
points, sold by the outside owners in proportion to their holdings.
The new project split is approximately **51.667% pooled, 17.222% direct,
31.111% producer**. Pooled investors' combined distributions, buyout cash
and unsold project-equity mark equal $66k against $60k initial; this
illustration yields a $6k risk-bearing nominal economic gain. Under lower
profits or a greater asset impairment, investors can lose capital. Buying
out a partner at original subscribed capital plus guaranteed profit
regardless of asset value is not the modeled product.

An individual producer's unrelated profit is not automatically shared;
only income from the designated project or other explicitly subscribed
enterprise rights is within its signed revenue/profit scope.

## Mutual incentives and possible conflicts

- Small or low-utilization producers should not be forced to subsidize
  larger producers without an approved shared-benefit rule.
- Large users pay fully allocated actual usage cost; no free underwriting
  of others' dispatch, logistics, storage or finance.
- Operators may prefer investments in their own enterprises: require
  abstention and independent approval, related-party pricing scrutiny,
  connected-investor caps and diversification controls.
- Distinguish **benefit from cheaper at-cost services** (patronage/user
  economics) from **profit of independently invested capital**.
  Tax authorities may treat patronage and nonpatronage sourced amounts
  differently: see [IRS Form 1120-C](https://www.irs.gov/instructions/i1120c).
- No promise that all projects are profitable, illiquid units can be redeemed,
  or continued membership guarantees financial returns. Member share
  NAV and capital impairment must be disclosed accurately.

## Legal and security HOLD gates

Cooperative member economic shares and project investment units can
constitute **securities**, especially where purchasers expect profits from
other people's managerial efforts. Review U.S. federal and applicable
state securities registration/exemption rules, broker/adviser and investment
company implications, state cooperative law, investor suitability/eligibility,
offer advertising, foreign investors and cross-border distribution **before
inviting subscriptions or publishing returns**. See
[SEC investor bulletin](https://www.sec.gov/files/investor/pubs/invclub.htm).
This model is *not* automatically exempt because it is a cooperative,
risk-sharing, interest-free or characterized as an Islamic finance product.

Conformity to an Islamic finance standard, where desired, requires
**independent qualified Shariah review** of profit ratios, loss exposure,
asset title, valuation, buyout promises, maintenance burden, contracts and
default treatment. An interest-free label alone is insufficient.

All financial capital authority remains outside the marketplace and
the unreviewed Biz-kit escrow/writer paths; only the appropriate legally
constituted asset issuer or approved regulated counterparty may admit the
capital instruments, cash and property transfers. Hawala's own native
books remain separately governed.

## Validation and simulation (research only)

A revised research-only 5-year NumPy/SciPy simulation tested **10 scenarios
× 200 fixed seeds = 2,000 synthetic cooperative economies** and 10 model
invariants. The only empirical-policy input is $250/year; every investor
participation, profit rate, market valuation, renewal, capacity, project cost
and buyout parameter is invented for stress testing. At baseline 1,000
initial producers (95% renewal, 8% annual recruitment), $50k projects
with 65/15/20 co-op/direct/producer shares, 16% modeled average net
project profit relative to original cost and 8% average asset wear:

- Mean five-year member capital contributions: about **$1.326 million**.
- Mean year-five co-op economic NAV: about **$1.429 million**.
- Mean co-op positive economic difference versus nominal contributions:
  about **$104k**, not realized cash distributable to members.
- **3%** of baseline synthetic runs have modeled co-op NAV below
  contributions; about **99%** in weak-profit scenarios and **100%**
  in recession scenarios. These are *conditional model frequencies*,
  **not empirical probabilities** of financial returns.
- The mean fifth-year baseline contains about **25.2 separate projects**;
  pooled investor cash from producer fair-value buyouts over five years
  averages about **$123k**, with no mandatory buyout of all remaining units.

Research code, fixed inputs, tests, charts and full replications are in a
file artifact delivered separately in the ChatGPT conversation. This PR
does not include or execute the research software in CI.

## Suggested next technically verifiable increment

Design a pure, **inert** membership-NAV and project-unit-cap-table kernel
plus Lean and Quint invariants (no issuance or movement of real money).
Pin independent asset project IDs, exact share fractions, membership
capital accounts, owner-signed subscription and source revisions,
positive/negative earnings, purchase-at-contemporaneous-value,
no forced par payoff, no dividend on unrealized profits, loss allocation,
revocation, replay/overpurchase, concurrent purchase, stale appraisal,
and no foreign authority in the local ledger. Admit only legally verified
operation types after governance, security and regulatory controls exist.

**No automatic shares, capital subscriptions, project offers, investor
payouts, buyout obligations or money movement are implemented here.**
