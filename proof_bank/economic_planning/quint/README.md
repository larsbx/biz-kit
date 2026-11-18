# Independent finite planning model

`planning.qnt` independently represents the pure contract in
`../lean/EconomicPlanning.lean`. It is synthetic verification evidence. It is
neither a forecast nor a deployed provider, reservation, trading or payment
interface. `checks.json` is the runner's explicit inventory of required positive
tests, the safe transition, and the deliberately unsafe variants.

## Finite scope

The context fixes one business scope, issue time 10, future horizon `[19, 23)`,
one source/model/scenario revision and seed, and USD as the cost currency.
Signal identity includes measure role, family, subject, material, grade, form, unit, currency,
location, instrument and maturity. Revision, unit, material and maturity
substitutions are separate fixture inputs. The time numbers are abstract ticks,
and the commodity/market data are invented.

The finite source catalog contains observed quantities, a known future-effective
source, an unknown quantity, a confirmed zero, four cost quotes, a foreign-currency
quote, one hypothetical quote, and adversarial records. `quantityKnown = false`
with canonical dummy quantity zero represents `none`; `true` represents `some`.
Unknown and confirmed zero are distinct. Source resolution and read authorization
are trusted fixture functions; the model does not authenticate them.

`ready` is computed from the empty state by applying the actual guarded evidence
admission function to nine ordinary source records. `reachablePreludeTest`
independently replays those nine action steps and requires exactly the resulting
state. The exhaustive fixture starts at this reachable prelude to avoid multiplying
every cost and publication ordering by every evidence-admission ordering.
Scripted tests also start from the empty state to exercise acceptance, rejection,
missing evidence and a future-effective announcement.

The shared physical pool has capacity two. Road, air and sea allocations all
consume that same pool. Additional catalog entries represent unknown capacity,
confirmed zero, a not-yet-effective quantity, a bucket outside the horizon and an
invented capacity inconsistent with its source, and a monetary quote mislabeled
as capacity. Only the first pool is usable in safe transitions. The model checks
the physical-quantity role and exact source/key/quantity links before use.
The independent invariant also inspects the resulting allocation records.

There are three canonical atomic cost components. An all-in quote covers two;
separate fuel and freight charges overlap it, and an insurance component is
disjoint. Components denote scoped economic effects, not a common news event:
different effects of one geopolitical shock must have different component keys.
Each cost line binds its admitted source, full signal, amount, currency, effective
period and the planning horizon. Its measure must be `moneyMinorUnits` and its
unit `minor-unit`; a physical quantity with USD metadata cannot become money.
Each source-bound total quote can appear in at most one line in a plan. Renaming
its component IDs does not permit replay of the same source total. All components
covered by a total quote belong in that one line; splitting one source total
across lines is not supported. Cross-report economic equivalence and component
canonicalization remain trusted host responsibilities.
A hypothetical quote must first enter evidence,
so publication cannot hide its provenance.

The finite envelope allows at most three accepted cost lines and two publications.
Accepted allocation lengths are naturally bounded by positive quantities and
capacity. Evidence is a set in this abstraction; Lean preserves an ordered list.
Each publication copies the complete current evidence, allocation and cost state.
An independent transition monitor checks the earlier publication prefix. All
planning transitions preserve the opaque operational token. The fixture has a
future horizon, so a `nowcast` classification is refused; Lean separately proves
the general current/future horizon classification contracts.

## Required evidence

The safe check uses the pinned Quint 0.33.1 and Apalache 0.62.4 translator with
Java 21 and TLC. It must finish exploring this finite graph with no invariant
violation and no states remaining in its queue. A depth-limited search is not
reported as complete exploration. TLC fingerprint collision estimates remain
part of its output.

The deterministic scripted scenarios require successful admissible paths as well
as refusals. These include use of a full shared pool in both air/sea orders,
known future information, disjoint charges after an all-in quote, a hypothetical
cost followed by scenario publication, and two immutable publication snapshots.

Every unsafe variant in `checks.json` must produce an actual counterexample to its
named invariant. The variants suppress an admission guard or deliberately corrupt
a publication/effect: late receipt or publication, substituted evidence or
revision, foreign scope, denied read, wrong resource attributes, invented capacity,
early capacity, out-of-horizon allocation, invented cost, assumed unknown
capacity, per-mode overbooking, overlapping or repeated cost components, mixed
currency, scenario downgrade, derived observation, rewritten history, future
nowcast, physical-as-money, money-as-capacity, total-quote replay under renamed
components, and operational mutation. The unknown-capacity mutant deliberately
substitutes a positive default for the absent quantity. Timeouts, deadlocks,
translation failures, syntax errors and generic nonzero exits do not satisfy a
negative control.

This is an independent finite abstraction, with no machine-checked refinement
relation to Lean or to an application/database. Arbitrary identifiers, quantities,
trace lengths and source catalogs are handled by the separately stated Lean
proofs. Neither model proves factual source truth, completeness, cryptographic
authentication, canonicalization of real-world resources/effects, statistical
calibration, or predictive accuracy. Snapshot context is fixed during a run;
new source versions require a new planning context and separately issued result.
