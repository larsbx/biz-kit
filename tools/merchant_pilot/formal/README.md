# Merchant pilot: Lean and Quint coverage

This layer specifies the offline intake/export measurement boundary introduced in #313 and #310.
It executes only synthetic inputs. Neither source identity nor commercial viability is established.

| Obligation | Lean model | Quint exploration | Runtime binding |
| --- | --- | --- | --- |
| Duplicate, consent and retention rules | General Boolean admission lemmas | Duplicate exclusion and sharing withdrawal | Existing adversarial exporter tests; Quint snapshots include a canonical duplicate anchor |
| Complete observation / denominators | Exclusive early-withdrawal, recent and mature buckets; exact boundary | Seven-day request cohort and incomplete coverage | Actual scorecard denominators checked from ITF; generated Lean examples check fixture bucket totals |
| Quote revision and merchant boundary | Exact structured revision key, acceptance prerequisites, expiry/withdrawal rejection, supersession cannot extend validity | Two immutable revisions; stale/foreign acceptance and withdrawal order | Actual exporter processes snapshots reconstructed from safe Quint traces; existing rejection tests exercise bad bindings |
| Unknown costs and reconciliation | Unknown/incomplete pools, unknown revenue, missing order and unallocated cost withhold full margin | Independent role-cost knowledge and source coverage | Generated actual-exporter Lean cases plus ITF projections compare null vs known cohort margins |
| Refunds and separate role contribution | General integer conservation, full refunds retain costs, refund effect on supplier | Partial/full refunds, fee reversals and three separate roles | 147 generated Lean equalities from Elixir observations; actual scorecard ITF replay |
| Currency separation | Currency-indexed amount type rejects mixed-currency addition | One currency in this model | Existing ExUnit currency tests; compile-negative Lean control |

## Reproduce on a server

Elixir 1.19 / Erlang OTP 27, Node 24, Java 17 and the repository-pinned Lean 4.35.0 and Quint 0.32.0 are used.
No app, database, provider credential or merchant record is required. From the repository root:

```sh
bash formal/lean/install-toolchain.sh /tmp/merchant-lean
elixir tools/merchant_pilot/formal/check_lean.exs \
  --lean /tmp/merchant-lean/bin/lean --leanchecker /tmp/merchant-lean/bin/leanchecker
npm install --prefix /tmp/merchant-quint --no-audit --no-fund @informalsystems/quint@0.32.0
bash tools/merchant_pilot/formal/install_apalache.sh /tmp/merchant-quint-home
QUINT_HOME=/tmp/merchant-quint-home elixir tools/merchant_pilot/formal/check_quint.exs \
  --quint /tmp/merchant-quint/node_modules/.bin/quint --verify
elixir tools/merchant_pilot/test.exs
```

Use a new installation directory, or reuse an already verified installation explicitly. The installer
checks the committed release archive digest. The Apalache installer likewise checks the official
v0.56.1 release asset digest and extracts without restoring archive ownership, including in root/container
environments. Its `QUINT_HOME` is separate from the npm tools directory. The Lean runner kernel-checks the model, replays its
imported environment with `leanchecker --fresh`, generates 147 examples against the actual Elixir
exporter/scorecard, and audits transitive axioms of every named theorem. Only the standard
`propext`, `Classical.choice`, `Quot.sound` are permitted. False full-refund arithmetic and mixed-currency
addition must fail compilation. No admitted proof or native decision oracle is permitted.

The Quint runner typechecks the model, runs twelve safe scenarios and five deliberate mutation
witnesses, explores 3,000 seeded traces of up to 25 steps, and separately emits 100 seeded simulator
traces plus the twelve safe scenario traces. `replay_quint.exs` reconstructs intake bundles from every
emitted state and compares actual acceptance, request denominators and all three role/currency cohort
margins to the model projection. A fixed extra canonical request exists only to represent duplicates;
its explicitly documented contribution is removed from the comparison. Stale coverage must produce
an actual coverage refusal. The model never supplies trusted output values to the exporter.

Five mutations must violate the same invariant: accept superseded revision, accept a foreign owner,
report an unknown expense as known zero, export stale coverage, and count a duplicate as demand.
Their test assertions require an invariant violation; parser errors or missing tools fail the run.
Mutation traces are deliberately excluded from safe implementation replay.

With `--verify`, Apalache must additionally establish the safety invariant through **eight transitions**.
Without it, the runner explicitly reports that bounded verification was not requested. Simulation and
scenario tests are not exhaustive model checking. Java/service/download failures are failures, not
verified results. The scoped merchant workflow runs both formal runners, including bounded checking.

## Scope and limitations

Lean proves mathematical properties of the model for arbitrary integer amounts and natural-number
timestamps. Generated equalities bind a finite synthetic corpus to actual Elixir outputs; this is not
a proof that all executions of the Elixir exporter refine the Lean definitions. A SHA-256-derived
runtime quote key is not proved injective by the structured Lean key theorem.

Quint covers one modeled request, a separate canonical duplicate anchor, one supplier, one servicing
store, two revisions, whole-day time points from 0 through 10, fixed example prices/costs, and partial
or full refunds. General timestamp boundary behavior, 30/90-day follow-up, failed/cancelled orders,
multiple orders, multiple currencies, source schema validation, malformed records and absent-store
cost contradictions remain covered by ExUnit tests and the relevant Lean predicates where listed.
The model permits one outstanding acceptance and captures immutable historical acceptance facts;
it does not model concurrent source writes, stock reservation or payment execution.

Consent, scope/participant approval, merchant identity, source ownership declarations, provider
verification and source completeness are trusted observations supplied by source owners. No theorem
or model check establishes their real-world truth, signatures, privacy compliance, authentication,
hosted portal accessibility, persistence behavior or production authorization. This layer writes no
business ledger and activates no collection or financial surface.

Validation status must be taken from the exact-head workflow and its tool output. A checked-in model
or generated test file alone is not an accepted proof or an observed merchant-economics result.
