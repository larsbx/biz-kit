# ADR: producer-owned at-cost cooperative and pooled capacity financing

Date: 2026-11-07. Status: **user-approved business model, proposed capital controls**.
Tracks [#328](https://github.com/larsbx/biz-kit/issues/328), with the
[demand-first pilot #308](https://github.com/larsbx/biz-kit/issues/308).
No legal entity is formed, capital fund operated, deposit accepted,
loan offered, ownership security issued, benefit distributed or financial
license granted by this ADR.

## User decision

The organization is a **producer cooperative**. Each admitted producing
business pays **$250 annually**. All core member services—**dispatch, logistics
capacity, member marketplace access, group purchasing, goods and any authorized
capital access/participation services**—are provided **at cost**, not at a
commission or markup intended to maximize platform revenue.

Producers pool their annual contributions to build shared **additional
productive capacity**. Returns or allocations to members are a core objective,
but the **mechanism is deliberately undecided**; do not substitute a
fabricated dividend, guaranteed investment yield or automatic $250 refund.

The product prioritizes qualified **wanted-item demand**, member supply
matching, independently viable consignment and procurement. Direct
person-to-person barter, international auctions, transferable credits and
multilateral financial clearing are **not critical-path dependencies**.
Existing Biz-kit per-business authority boundaries, federated discovery,
and Hawala financial-owner restrictions remain unchanged.

## Financial separation / invariant

There are **at least six separately accounted ledgers or sub-ledgers**, under
appropriate governing authority—never a new network money writer:

1. **Annual member contributions**: exact $250 per eligible producer/year.
   Status as annual membership fee versus capital contribution/equity share
   is **TBD**, jurisdiction- and charter-dependent. Do not call it refundable
   equity without a separately legally effective capital contract.
2. **Service operating collections & cost true-up**: dispatch, freight,
   shared logistics, marketplace operations, group procurement and other
   services priced on a transparent **fully allocated total cost basis**.
   Collect/return differences using a documented cost-pool policy; a cost
   overcharge is not free funds for unrelated investments.
3. **Shared-capacity assets**: equipment or software ownership, original
   capex, maintenance, depreciation, replacement schedule, impairment,
   utilization and responsible operator.
4. **Restricted asset-replacement & risk reserves**: maintained before
   expansion or distributions. A non-cash accounting depreciation entry
   requires explicit cash funding through service fees if it is to finance
   replacement.
5. **Member capital access/investments**: if authorized, separate, capped
   interest-free business-loan receivables (principal, term, underwriting,
   defaults, risk reserve, conflicts) from any separately subscribed
   equity/project opportunities (rights, valuation, losses, securities review).
   Neither is a cash dividend from ordinary goods trades.
6. **Member-specific allocations/redemptions**: only after legal accounting
   classification, contractual and statutory authority, adequate reserve,
   member governance and independently verified cash and attribution.

No pooled money, member contribution, shared asset or business receivable
may be treated as Hawala-native credit, customer custody, or transferable
purchasing power. Financial services require their own permissions and
potentially a legally distinct regulated partner.

### Fully loaded at cost means more than zero markup on unit purchase price

Each service tariff must recover actual attributable direct costs **plus** a
reasonable allocated share of back-office labor, risk and insurance,
maintenance, depreciation and capital replacement, tax and compliance,
claims, technology, dispatch support, vendor handling and financing
administration. If a separate project intentionally prices below this full
cost, the shortfall must be funded by a specific capped, authorized subsidy.
Using membership contributions to conceal chronically uncovered losses
would erode the very capital the members intend to accumulate.

Member goods sold at cost are an exchange under the supplying producer's
contract, inventory and taxes. Their gross selling prices and payments are
**not automatically cooperative operating revenue**. The cooperative must
identify its own legal and accounting role, if any, in a sale.

## Member economic value / participation

Producer utility comes from the sum of attributable **real-world benefits**:

- Lower verified cost of dispatch, freight, warehousing, logistics and
  shared capacity than available outside options.
- Collective purchasing savings, including procurement fees and handling.
- More fulfilled qualified buyer wants at cost, with transparent margin,
  transport, inventory risk and opportunity cost for each member.
- Business capital access with appropriate credit, security and
  governance protections.
- Capacity availability, avoided idle inventory, and improved throughput.

These benefits **belong to the member enterprise**, not cooperative cash
receipts, until and unless a lawful underlying transaction realizes actual
cooperative revenue. At `u` annual service uses, savings to cover annual
dues by this channel alone require at least `250/u` dollars per use,
**plus** any incremental producer-specific costs. This is an accounting
identity—not a forecast of outside-market savings or member renewal.

Member participation should be monitored separately from co-op solvency,
including low-usage members and any economically inequitable service/capital
allocation. Governance should decide fair use, queue priority, regions,
access limits, board oversight and conflict resolution, not invent rewards
based only on ledger balances.

## Capital return and allocation options (NONE selected)

- **Member service credits/true-ups:** Return verified overpayments relative
  to full actual costs, or grant capacity access following independently
  approved fair-use rules. This is not investment return.
- **Patronage distributions:** If there is eligible patronage-sourced net
  margin, distribute or retain it according to actual member patronage under
  Subchapter T and relevant charter/tax rules. There may be no eligible
  margin under full-cost service pricing.
- **Allocated/revolving cooperative equity:** If separate member capital
  accounts and sufficient legal authorization exist, designate retained
  equity and later redeem older eligible allocations subject to solvency.
  Annual *dues* must not silently be repackaged as refundable equity.
- **Interest-free capital access:** Make separately approved business loans
  with principal-only amortization, adequate credit-risk limits and loss
  allocation. Zero interest does not eliminate depreciation, inflation,
  administrative expense, opportunity cost or defaults.
- **Opt-in member project investment:** An independently structured
  subscription to productive-capacity equity or revenue participation,
  subject to governance, security offerings rules and the possibility of
  loss, distinct from guaranteed at-cost services.

**Cash conservation:** Pooled capital at end of period is previous liquid
capital plus lawful contributions and recovered principal minus authorized
capex, loan originations, capital-serviced operating shortfalls, losses and
approved member payments (plus other verified allowed cash flows). Existing
physical assets and loans are **not** distributable cash. Do not count dues
again as economic output when equipment is acquired or debt is repaid.

## Five-year synthetic scenario (NOT measured or calibrated)

A research-only 17-scenario × 200-seed, five-year NumPy/SciPy stress test
used **$250 annual dues** as the user-defined input. For an invented
1,000-member initial cooperative with 95% retention and 8% recruitment
(relative to prior membership), $50k modules yielding 1,200 service
operations per year, 7-year straight-line depreciation recovered in at-cost
invoices, a replacement cash reserve, $5k interest-free 2-year loans with 2%
modeled defaults, and a 25%-of-dues liquidity floor:

- Mean five-year total dues collected: about **$1.326 million**.
- Mean capital outlay: **$250k** for five hypothetical modules.
- Mean fifth-year pooled cash: **$826k**, including about **$121k restricted
  replacement reserve** (therefore about $705k unrestricted modeled cash).
- Mean fifth-year outstanding nominal loan principal: about **$355k**.
- Those cash and asset balances are **not profits, guaranteed capital values,
  distributable patronage, or empirical proof of member usefulness**.

Model outputs depend on assumptions, and **no member benefits or savings
were empirically established**. The separate chat research ZIP contains
replicates, manifests, source, charts and eight passing invariants. The ZIP
is not committed to this repository and hosted CI has not reproduced it.
If the model is incorporated into repo CI, port exact source and pinned
dependencies, not just these summary numbers.

The modeled conditional 15% year-five member-cash-redemption variant is a
**sensitivity experiment only**, not a recommended distribution or lawfully
established redemption of annual dues. The base implementation distributes
zero cash automatically.

## Engineering work remaining

1. Source-backed legal business and authorized-agent eligibility as in #302.
   Member admission is distinct from consumer buyer access.
2. Canonical `MemberMembershipYear` accounting with payable/paid/refunded,
   immutable receipt and correct fee-versus-equity legal characterization.
3. Cost pool and at-cost rate specification for dispatch, logistics, goods,
   group purchasing and marketplace: full cost, evidence, usage, fair
   allocations, depreciation, invoice collection and member true-ups.
4. Productive asset and approved project portfolio: title, utilization,
   capex approval, replacement and risk reserves, financing terms and
   liability boundaries.
5. Financial product authority: interest-free business financing and any
   project investment must not be activated absent a regulated/legal
   capability review, current producer authority and safeguarding.
6. Fair member-benefit measurements and annual renewal cohorts; do not
   reuse merchant contribution margins from the old commission model.
7. Specific governing and statutory rules for any cash distribution,
   retained equity, capital redemption and unwinding. Perform fiduciary
   and independent legal/tax review before accepting capital.
8. Maintain wanted-registry, merchant offers, store-controlled fulfillment,
   evidence and demand economics as the first commercial pilot (#308).

## External framework (background, not evidence of this model)

- [USDA, cooperative equity financing](https://www.rd.usda.gov/sites/default/files/publications/CIR_45-7.pdf)
- [USDA, revolving member equity](https://www.rd.usda.gov/files/cir44-3.pdf)
- [IRS, Form 1120-C cooperative/patronage reporting](https://www.irs.gov/instructions/i1120c)
- [SEC, membership interests and investment contracts](https://www.sec.gov/files/investor/pubs/invclub.htm)

No public member financing, investment advertising, custody, deposits or
member cash distribution is authorized by this proposed architecture.
