# Economic planning: verification layer before integration

Date: 2026-11-11 (America/New_York).
Decision: **Accepted direction; verification implementation precedes data adapters,
economic estimators, spatial presentation, and operational integration.**

## Purpose and scope

Combine the God's Eye View spatial workspace and existing academic economics
research into source-bound nowcasting, forecasting, and conditional capacity
planning. This extends [GEV-08](../plans/2026-11-11-dispatch-spatial-workspace.md#gev-08--business-network-analysis).
The owner's explicit scope includes road, air, sea, rail, inland waterways,
intermodal handling, storage and production; environmental and infrastructure
conditions; fuel and energy; global markets and central banks; geopolitics;
commodities and precious metals.

The first implementation is the inert
[economic-planning Proof Bank](../../proof_bank/economic_planning/README.md).
It implements and verifies planning admission and publication contracts. It does
not implement a statistical estimator, production data adapter, live feed, GEV
panel, business reservation, trade, accounting entry, or settlement operation.

Source baseline at kickoff: main
`eae9f14b5533f660d1a48b9b438e5066f566beff`. The separate
[Dispatch spatial PR #371](https://github.com/larsbx/biz-kit/pull/371) was open and
draft at `9a00579786610e834464faef4e936095c26283cb`. This proof package is based
on main and does not import that PR's application changes. Its verification
cannot promote the separate Dispatch work to merged, deployed or field-verified.

## Accepted input domains and mechanisms

| Domain | Required representation at later adapter integration |
| --- | --- |
| Multimodal activity | Resource identity, compatible demand, time buckets, nominal/serviceable/committed capacity, actual cargo availability, queues and transfers. Visible aircraft or vessels alone do not establish spare capacity. |
| Environment and infrastructure | Evidence of conditions, exposed assets/routes, effect intervals, and explicit mechanisms such as closure, service-time change, energy interruption or recovery. |
| Fuel and energy | Product grade, purchase location, delivered price, contract timing, currency, physical consumption and inventory. Count components already included in a quote once. |
| Global markets | Exposure-specific FX, prices, credit conditions, freight indicators and real activity. Preserve observation frequency, instrument identity, publication time and revision. |
| Central banks | Decisions, effective dates, balance sheets, liquidity operations, statements and expectations as separate observations. Distinguish announcements, surprises, market responses and modeled transmission. |
| Geopolitics | Observed events, enacted measures, proposals and hypothetical scenarios; exact product, entity, route and jurisdiction applicability. Distinct effects of a common event remain distinct. |
| Commodities | Agriculture, industrial metals, critical minerals, fertilizers and other raw materials: grade/form/location, production, processing, inventories, shipments and compatible business demand. |
| Precious metals | Gold, silver, platinum, palladium and relevant specialty metals: purity, fine-metal quantity, market location, physical premiums, industrial/investment/recycling demand, and official gold holdings versus transactions and valuation. |

Every domain feeds the same provenance and planning contracts. Scope inclusion
does not claim that a provider is connected or its data is comprehensive.
The future registry must retain data access terms, source coverage and freshness.

Sources useful for later adapter evaluation include
[World Bank commodity data](https://www.worldbank.org/en/research/commodity-markets),
[USGS mineral summaries](https://pubs.usgs.gov/publication/mcs2026),
[LME warehouse reports](https://www.lme.com/Market-data/Reports-and-data/Warehouse-and-stocks-reports),
[LBMA benchmark specifications](https://www.lbma.org.uk/prices-and-data/lbma-precious-metal-prices),
[IMF reserve reporting](https://data.imf.org/Datasets/IRFCL/Reporting-Template),
[WTO restriction notifications](https://data.wto.org/dataset/ext_qr),
[EASA conflict-zone information](https://www.easa.europa.eu/en/domains/air-operations/information-on-conflict-zones)
and [IMF PortWatch](https://portwatch.imf.org/). These references establish candidate
data semantics, not an authenticated source snapshot in the kernel.

## Verification contract

### Evidence and time

A planning context freezes scope, issuance time, horizon, source lookup, resource
catalog, model revision, snapshot revision, scenario identity, seed and accounting
currency. Source references identify a particular source revision; signal keys
separately identify family, subject, material, grade, form, unit, currency,
location, instrument kind and maturity.

Admission requires the expected reference and complete key to match the actual
record supplied by the frozen source lookup. A read-authorization assertion must
permit that record in the context's scope. Both publication and receipt times
must be no later than issuance. A record reported tomorrow cannot enter today's
original forecast, even when its underlying event happened yesterday.

Future-effective announcements already known at issuance can be admitted as
evidence. Their modeled physical quantity can only support allocations during
its applicable interval and the selected planning horizon. A later source
revision requires a new context and new publication; existing certificates
remain the original immutable values.

The host supplies authenticated timestamps, canonical source identity, the
truth of observations, grant validity, and complete evidence. The Lean model
does not authenticate those assertions or infer them from a map, digest or URL.
Provider text is data and supplies no execution authority.

### Quantities and shared capacity

Capacity is an optional exact natural number. Unknown capacity is distinct from
confirmed zero, and neither permits a positive allocation. A requested quantity
must match the frozen resource's source and complete material/signal identity;
the capacity value must match an admitted evidence payload.

One canonical resource constraint and time bucket have one shared bound across
all transport modes. An air, sea or road label does not create additional supply.
Accepted allocations preserve the sum-of-allocations bound, including competing
requests and arbitrary accepted sequences from the declared opening state.

This is a scalar capacity bound for each declared constraint. It is not yet a
proof of network flow balance, inventory conservation, production recipes,
multi-dimensional shipment feasibility, route continuity or stochastic service
levels. The host must supply canonical resource identities, a consistent atomic
time partition, and all required dimensions. Overlapping arbitrary intervals
must first be expanded into that partition. This kernel does not infer physical
identity from independently reported aliases.

### Cost components and economic effects

Cost lines are source-bound exact amounts in one accounting currency, with a
monetary measure tag and canonical `minor-unit` denomination. A physical
quantity or market rate cannot be interpreted as a total monetary charge. Their
atomic component identifiers must be nonempty, unique within a line, and
disjoint from components already included in the plan. An all-in freight quote
can cover freight, fuel and insurance; adding an already covered fuel component
is refused. Each source-bound total quote is single-use, including when someone
renames its component identifiers. All its components belong in one cost line;
separate exposures need separately identified source totals. A hypothetical
cost must inherit hypothetical evidence and force a scenario publication.

Component identity represents the same economic effect for the same exposure,
channel and period. It is not a news-report ID or a common-shock ID. A single
geopolitical event can legitimately affect sea transport, fuel and FX through
different components. Resolving two reports to the same economic effect remains
a host/provider obligation; the kernel enforces uniqueness after canonicalization.

The first slice checks supplied cost totals and component coverage. It does not
compute commodity unit conversions, purity adjustments, FX, tariffs, price
pass-through, futures carry, procurement cash flow, inventory valuation or
realized profit. Spot, forward, futures and physical material identities must
not be substituted for each other. A futures quote is an observed instrument
price; using it as a spot-price forecast needs a separate validated model.

### Publication and authority

Publication freezes the complete admitted evidence, allocations, cost lines and
manifest. Derived output cannot be labeled an observed fact. Synthetic or
hypothetical evidence forces a scenario label. Ordinary fitted parameters and
model uncertainty belong to the versioned model; they are not automatically
counterfactual interventions.

A nowcast horizon contains issuance time; a forecast horizon starts strictly
after it. Scenarios may address any nonempty horizon. These are declared
classification rules for this slice, not an empirical test of an estimator.
The required snapshot/model identifiers are host-supplied bindings; the kernel
does not hash or authenticate the data behind those identifiers.

The pure transition system preserves an opaque operational-state token and all
previous publications. It has no network, database, credential, order,
reservation, accounting, trading or settlement entry point. The theorem applies
to accepted traces from `initial` under one frozen context. A later runtime
adapter must reconstruct that trace or establish a corresponding validated
state; it cannot deserialize an arbitrary state and cite the theorem as proof.

The intended runtime keeps Dispatch, Commerce and the existing domain owners in
control of business mutation. A forecast publication is an analytical record.
Any subsequent action must use the existing currently authorized command path.

## Relationship to the economics research

Reuse the [merchant pilot's immutable intake and metric definitions](../../tools/merchant_pilot/README.md)
when relevant, and the accepted
[producer cooperative](2026-11-07-producer-coop-at-cost-capital-pooling.md) and
[risk-bearing equity](2026-11-07-diminishing-producer-equity.md) accounting
distinctions. Member savings, traded volume, operating revenue, liquid assets
and distributable earnings are separate quantities. External interest-rate
conditions do not create an internal interest charge or guaranteed return.

Existing synthetic economics studies supply research hypotheses and scenario
engines. They are not calibrated live forecasts. Formal admission proofs and
empirical forecast evaluation remain separate evidence classes.

## Delivery order and gates

| Milestone | Deliverable | Required evidence before advancing |
| --- | --- | --- |
| EPV-01 | Inert planning contracts and verification package | Lean theorem/type/axiom checks, fresh kernel replay, executable positive/negative scenarios, independent finite Quint exploration, and validated guard-removal counterexamples tied to exact source/tool identities. |
| EPV-02 | Pure serialization and domain adapters | Strict schema/units, authenticated scoped reads, exact source revisions, canonical resource/component identities, source-time replay, and differential tests against the verified transition semantics. |
| EPV-03 | Baseline nowcast/forecast adapters | Explicit model/data/parameter versions, uncertainty, missingness and coverage; rolling issuance-time evaluation against simple baselines using only information then available. |
| EPV-04 | Multimodal and economic scenarios | Inventory/flow and recipe constraints, correlated shocks, scenario sensitivity, cost reconciliation, recovery and commissioning assumptions. One actual sea/air/inland corridor can be the first validation slice without narrowing the architecture's scope. |
| EPV-05 | Authorized GEV planning view | Source/assumption drill-down, issuance and valid-time navigation, scenario comparison, clear unknown/unavailable states, read authorization/revocation, browser and integration acceptance. |

No additional service, datastore or operational writer is selected by EPV-01.
Use existing platform storage and bounded execution when subsequent milestones
require them. Publish evidence with separate `implemented`, `local-verified`,
`hosted-verified`, `field-verified` and `deployed` labels. Bounded model checking
must state its finite domain; machine-checked invariants do not establish
economic causation, data truth, forecast calibration or live deployment safety.
