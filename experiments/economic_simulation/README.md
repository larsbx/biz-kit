# Economic simulation experiments

This package provides a synthetic B2B marketplace simulator, exact barter-cycle matching, paired policy comparisons, and optional Mesa and NegMAS demonstrations. Its Python functions and JSON CLI are the boundary for a future testing interface. The core uses Python 3.12 and the standard library. There is no HTTP endpoint or user interface in this package.

The implemented models separate invitations, actionable quotes, mutual commitments, exclusive stock reservations, physical delivery, and buyer receipt. They are original experiments with inspectable assumptions. They are not calibrated forecasts or replications of the papers in [sources.json](sources.json), and they do not execute commerce, payments, or settlement.

## Run an experiment

Run these commands from the repository root. Use a Python 3.12 interpreter; `python` below denotes that interpreter.

```sh
mkdir -p experiments/economic_simulation/out

python -m experiments.economic_simulation models

python -m experiments.economic_simulation run \
  experiments/economic_simulation/examples/demand_first.json \
  --seed 0 \
  --output experiments/economic_simulation/out/demand_first.seed_0.json

python -m experiments.economic_simulation sweep \
  experiments/economic_simulation/examples/demand_first.json \
  --policies experiments/economic_simulation/examples/policies.json \
  --replicates 30 \
  --seed-start 0 \
  --output experiments/economic_simulation/out/demand_first.comparison.json
```

Without `--output`, commands write JSON to standard output. Create the output directory first. Invalid scenarios and exhausted simulation or solver budgets are errors, not successful partial results.

| Example | Purpose and assumptions |
| --- | --- |
| [demand_first.json](examples/demand_first.json) | 100 requests, five suppliers, two structurally feasible suppliers per request, 28 days of intake, and another 168 hours of observation. Response and delivery probabilities are synthetic inputs. |
| [multi_area.json](examples/multi_area.json) | 40 requests across two areas and two categories. Each scoped supplier lot has its own capacity; the same business may own lots in several scopes. |
| [barter_fragility.json](examples/barter_fragility.json) | A five-party ring with staggered deliveries and a designated failing supplier. It exposes irreversible partial performance after all parties have committed. |
| [policies.json](examples/policies.json) | Named immediate, daily, two-day, and reliability-adjusted policy variants. The first entry is the paired-comparison baseline. Read the actual overrides before comparing results. |

Run the other scenarios through the same command:

```sh
python -m experiments.economic_simulation run \
  experiments/economic_simulation/examples/multi_area.json --seed 0

python -m experiments.economic_simulation run \
  experiments/economic_simulation/examples/barter_fragility.json --seed 0
```

## Make another area or category explicit

Generate a scenario first, inspect its JSON, then run it. Generation chooses the market's request times and compatible lots; the later simulation seed controls response, commitment, and delivery primitives. Preserve both seeds.

```sh
python -m experiments.economic_simulation generate \
  --seed 17 \
  --requests 100 \
  --suppliers 10 \
  --feasible-suppliers 2 \
  --areas metro-a,metro-b \
  --categories materials,packaging \
  --intake-hours 672 \
  --output experiments/economic_simulation/out/two_area.scenario.json

python -m experiments.economic_simulation run \
  experiments/economic_simulation/out/two_area.scenario.json \
  --seed 3 \
  --output experiments/economic_simulation/out/two_area.seed_3.json
```

Area, category, and unit require exact equality. There is no inferred substitute, cross-area transport, unit conversion, or exchange rate. `acceptable_offer_ids` controls structural thinness independently of response probabilities. An empty list permits no offers; `null` permits every otherwise compatible offer. Prices and costs use integer minor units of one declared currency, and quantities are indivisible positive integers.

The generator creates a separate supply lot for each supplier–area–category combination. Adding scopes consequently adds physical stock; it does not partition a fixed shared warehouse. Business-level parameters and exits can still affect all lots belonging to that business. Model shared resources explicitly before interpreting a multi-area comparison as a capacity-allocation experiment.

## Implemented mechanisms

### Demand-first procurement

Requests enter at their explicit qualification times. Compatible suppliers receive invitations, may respond after a configured delay, and can issue a quote only while stock, price, availability, and the request's original deadline allow it. Quotes are immutable price/quantity revisions. A commitment requires both parties' acceptance and revalidation of exclusive stock capacity.

`policy.cadence_hours` is `0` for immediate clearing or a positive integer for periodic clearing from hour zero. Any explicit integer-hour interval is supported; 24 and 48 are example experiments. Batch waiting can make more quotes available while reducing time left to deliver.

| `policy.selection` | Selection rule |
| --- | --- |
| `first_quote` | Earliest available quote, with lower total price and stable identifiers breaking ties. |
| `lowest_cost` | Lowest quoted total among currently actionable quotes. |
| `reliability_adjusted` | Quoted total plus `(1 - seller fulfillment probability) × failure_penalty_minor`. This penalty affects ranking; it is not a charged fee or an observed loss estimate. |

This is a posted-quote procurement selection model. It does not simulate strategic auction bids, equilibrium behavior, reserve learning, or the published PyMarket mechanisms. Reliability parameters are scenario assumptions, not inferred merchant scores. A request uses one supply lot: split sourcing and partial fills are not implemented.

The default USD `annual_membership_fee_minor` value is 25,000 ($250). It is metadata; the simulator does not accrue membership income, returns on capital, or profit from it. Posted prices can represent declared at-cost terms, but the model does not establish that they recover fully allocated costs. `coordination_cost_minor_per_order` charges a synthetic cost to each committed order, including retries and individual barter legs. It omits unmodeled costs such as unsuccessful outreach unless the model is extended explicitly.

### Barter cycles

Each barter request links its owner's distinct outgoing lot through `exchange_offer_id`. A directed edge means that outgoing lot can satisfy another request under declared compatibility. Multiple slots may belong to one business, but the same physical lot cannot be duplicated into several independent slots. The solver maximizes the number of matched slots, not monetary welfare or business-level utility.

Cycle length is unrestricted by default: `max_cycle_length: null`. The unrestricted solver uses exact assignment and extracts its nontrivial cycles. Setting a cap such as 2, 3, or 4 invokes an exact bounded-cycle packing experiment. These caps are sensitivity controls, not architectural limits on exchange membership. Both algorithms enforce an explicit deterministic work budget and refuse to label an interrupted search optimal.

All participating businesses must accept a proposed cycle before its legs reserve inventory. This collective commitment is distinct from delivery. Compatibility and the acceptance probabilities supply willingness-to-trade assumptions; there is no hidden conversion of posted prices into barter utility, no budget balancing through side payments, and no proof of realized individual benefit.

### Execution, withdrawal, and recovery

Before delivery, a failure or cancellation releases reserved stock. After delivery, stock remains consumed: delivered goods do not return automatically when another leg fails. A failed cycle cancels its unfinished, undelivered legs while preserving deliveries and subsequent receipt evidence.

Buyer receipt is modeled as automatic acceptance after `receipt_delay_hours` following delivery. There are no quality inspections, disputes, partial receipts, returns, or uncertain acceptance after arrival. Thus even this stronger receipt measure remains a synthetic operational proxy.

`business_exit` shocks remove a business from future participation. `carrier_outage` shocks postpone affected deliveries until the outage ends, providing a common disruption across an area. Future shocks do not inform the current matching decision. Original request deadlines and order promises remain unchanged, so a delayed or recovered transaction can still miss its original target.

`rematch_rounds` permits a bounded number of additional attempts after failure; it defaults to zero. Recovery needs capacity, active counterparties, and a renewed actionable quote. It does not erase the initial failed order or reset the request's qualification clock.

## Read the metrics with their denominators

Seven days means 168 elapsed hours from each request's qualification. A request is **mature** only when its full window is observable at the scenario cutoff. Boundary events at hour 168 count. Rates include their exact numerator and denominator; a zero denominator yields `null`.

| Metric | Numerator | Denominator |
| --- | --- | --- |
| `quote_rate_7d` | Requests with an actionable quote within seven days | All mature requests, including early withdrawals |
| `commitment_rate_7d` | Requests with mutual, capacity-backed commitment within seven days | All mature requests |
| `fulfillment_rate_7d` | Requests with modeled buyer receipt/acceptance within seven days | All mature requests |
| `pilot_quote_rate_7d` | Mature, pilot-eligible requests with a qualifying quote in the window | Mature requests excluding withdrawals before the window closes |
| `original_due_date_fulfillment` | Requests accepted by the buyer by their original due date | Qualified requests whose original due date is observable |
| `original_promise_reliability` | Accepted orders physically delivered by their original promise | Accepted orders whose original promise is observable |
| `final_outcome_delivery_rate` | Physically delivered accepted orders, on time or late | Accepted orders with delivery, failure, or cancellation observed; pending orders excluded |

The first three metrics share a denominator and form a quote → commitment → receipt funnel. A later failed order does not erase a historical quote or commitment. Early withdrawals remain in that experimental funnel so policy attrition stays visible; the canonical pilot uses its own eligibility rule.

Inspect `immature_requests`, early withdrawals, pending and overdue orders, and `delivered_awaiting_buyer_acceptance` alongside rates. A shorter observation horizon cannot turn pending work into a demonstrated success or failure. The demand-first fixture includes a full seven-day follow-up after its last possible intake time.

For barter, inspect `committed_cycles`, `fulfilled_cycles`, and the individual order/event records together. `stranded_outgoing_legs` counts physically delivered outgoing legs whose source's own request has not reached buyer acceptance by cutoff. `stranded_value_at_cost_minor` sums those legs' recorded unit price times quantity, treated as declared cost. It measures outstanding exposure at that cutoff, not an established permanent loss or a participant's utility.

Supplier order concentration includes committed order attempts, including retries. Coordination cost also counts those attempts. Neither measure is a statement of realized sales or cooperative margin.

## Use the existing canonical pilot reader

The authoritative procurement measurement implementation remains [CommerceCore's merchant pilot](../../apps/commerce_core/lib/commerce_core/merchant_pilot/) and its [offline scorecard guide](../../tools/merchant_pilot/README.md). This package exports purchase simulations into that existing v1 contract; it does not replace the reader.

```sh
python -m experiments.economic_simulation pilot \
  experiments/economic_simulation/out/demand_first.seed_0.json \
  --output experiments/economic_simulation/out/demand_first.pilot.json

elixir tools/merchant_pilot/cli.exs score \
  experiments/economic_simulation/out/demand_first.pilot.json
```

The canonical command requires Elixir 1.19 and Erlang/OTP 27+. Its seven-day match means an actionable qualified quote, not an accepted order. It excludes early request withdrawals from the mature match denominator and does not qualify a quote withdrawn at issuance. A quote withdrawn later retains its historical qualification. Its fulfillment measure uses evidenced physical delivery among accepted orders with final outcomes; pending orders remain separate. That measure is distinct from this simulator's buyer-accepted `fulfillment_rate_7d` over all mature requests.

The exporter deduplicates invitations by merchant/request and retains observed events through cutoff. It leaves payment, reconciliation, platform fees, and unmodeled costs unknown. A simulated quote is not payment evidence, and missing financial inputs do not become zero. The export is labeled synthetic and rejects barter because pilot v1 does not represent these barter commitments. Stable synthetic ID hashes are for fixture interoperability, not an anonymization method for live source identifiers.

## Reproduce comparisons

`sweep` gives each policy a fresh state and uses the same seeds and keyed random primitives for corresponding business/request/offer events. A different policy can cause different events; it does not inherit the baseline's inventory or outcomes. Results report means, standard errors across replicates, and paired differences against the first named policy. These quantify variation under the chosen synthetic assumptions, not confidence in a field effect.

Preserve the normalized scenario, policy map and order, generation seed, run seeds, package revision, Python version, and dependency lock. Each core result records scenario and model-source hashes, the Git revision when available, dirty-tree status, and the random-primitive version. Repeat a run against unchanged code and inputs before extending its interpretation.

Useful initial sensitivity tests are one versus two versus several feasible suppliers; immediate versus 24/48-hour clearing; slower or less likely responses; stock contention; lower fulfillment probability; one supplier exit; a shared carrier outage; zero versus a small rematch allowance; and unrestricted versus explicitly capped barter cycles. Vary one assumption or a declared factorial design at a time, then inspect the event traces when a policy changes the funnel. Synthetic improvement is a reason to test a mechanism prospectively, not a pilot pass criterion.

Resource controls are part of the scenario: `max_events`, `max_candidate_pairs`, and `solver_work_budget`. Their defaults are 100,000, 50,000, and 1,000,000 respectively. Solver work units are deterministic counters, not elapsed seconds or a memory bound. Raising them changes the allowed computation, not the empirical credibility of a scenario.

## Optional research runtimes

[sources.json](sources.json) records source links, reviewed versions, licenses, and what is actually integrated. The standard-library engine imports neither runtime.

| Adapter | Pin and license | Implemented scope |
| --- | --- | --- |
| Mesa | `mesa==3.5.2`, Apache-2.0 | Actual `Model`/`Agent` participation and response demonstration with stable activation and seeded randomness. A response is not a qualified quote. |
| NegMAS | `negmas==0.17.0`, AGPL-3.0-or-later | Actual bilateral SAO integer-price negotiation with original bounded concession strategies. Agreement does not imply fulfillment. |

Install the reviewed versions and transitive dependencies from `uv.lock`, using uv 0.13.6. The default development group includes `jsonschema==4.23.0` for interface-contract tests; it is not a core runtime dependency. These commands also run from the repository root, so Python can import `experiments.economic_simulation`:

```sh
uv sync --project experiments/economic_simulation \
  --frozen --extra research --python 3.12

uv run --project experiments/economic_simulation --frozen --extra research \
  python -m experiments.economic_simulation adapter mesa \
  --seed 0 --steps 7 --agents 10

uv run --project experiments/economic_simulation --frozen --extra research \
  python -m experiments.economic_simulation adapter negmas \
  --seed 0 --buyer-limit 120 --seller-floor 80 --max-rounds 20
```

Use the `mesa` or `negmas` extra to install just that runtime. `research` opts into both, including NegMAS's AGPL dependency. No third-party implementation is vendored. Both adapters return independent JSON demonstrations; they do not drive the core engine, and their output contract is separate from the core scenario/result schemas.

NegMAS's own runtime consumes unused global random draws even when random termination is disabled. The adapter's economic decisions use private seeded streams and deterministic round counters, so unrelated draws do not affect its result. Use separate process workers for concurrent NegMAS jobs; this wrapper does not swap shared global RNG state. Neither adapter models physical delivery. SCML, KEPSurvey, and PyMarket remain source references, not installed integrations or reproduced experiments.

## Python and JSON interface

```python
from experiments.economic_simulation import compare, simulate
from experiments.economic_simulation.scenario import load_json

scenario = load_json("experiments/economic_simulation/examples/demand_first.json")
result = simulate(scenario, seed=0)
comparison = compare(
    scenario,
    {
        "immediate": {"cadence_hours": 0},
        "daily": {"cadence_hours": 24},
    },
    seeds=range(30),
)
```

`simulate` validates without mutating its input. Its result includes normalized scenario, provenance, metrics, invitations, quotes, orders, cycles, inventory, solver diagnostics, and a sequenced event log. A future interface can submit an explicit scenario and render these records without assigning business authority to the simulator.

```sh
python -m experiments.economic_simulation schema scenario
python -m experiments.economic_simulation schema result
```

The published [scenario](schemas/scenario.schema.json) and [result](schemas/result.schema.json) schemas describe the core JSON boundary. Runtime validation additionally checks references, temporal ordering, currency/quantity constraints, duplicate IDs, and stock invariants. The CLI JSON loader rejects duplicate keys and non-finite numbers. No server, authentication, background queue, database, or endpoint is implemented here.

## Validation

Run the core and adapter validation tests without adding research dependencies:

```sh
python -m unittest discover -s experiments/economic_simulation/tests -v
```

Optional runtime tests report explicit skips when their library is absent. For an integration check, assert both installed versions and run the suite in the frozen environment:

```sh
uv run --project experiments/economic_simulation --frozen --extra research \
  python -c "from importlib.metadata import version; assert version('mesa') == '3.5.2'; assert version('negmas') == '0.17.0'; assert version('jsonschema') == '4.23.0'"

uv run --project experiments/economic_simulation --frozen --extra research \
  python -m unittest discover -s experiments/economic_simulation/tests -v

python experiments/economic_simulation/tests/pilot_interop.py --require-elixir
elixir tools/merchant_pilot/test.exs
```

The required Elixir interoperability flag fails when the reader cannot execute; an unavailable runtime is not a parity result. Tests exercise semantic boundaries such as inventory conservation, maximum-cardinality cycle selection, bounded failures, immature windows, irreversible deliveries, retry timing, and canonical export controls. They establish properties of this implementation and its synthetic fixtures, not the behavior of a live marketplace.
