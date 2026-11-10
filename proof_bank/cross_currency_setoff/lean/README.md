# Lean exact-rational setoff model

Pinned compiler: **Lean 4.35.0**, importing only `Init`; no Mathlib or external Lean packages.

`CrossCurrencySetoff.lean` supplies 40 universally quantified theorems. `Contracts.lean` separately states 40 expected proposition types, including expanded arithmetic formulas and the original cross-multiplication definition of exactness. `proof_targets.json` fixes the theorem inventory. `AxiomAudit.lean` audits the compiled declarations; the permitted foundational axioms are `propext`, `Quot.sound`, and `Classical.choice`. There are no added axioms, admitted proofs, `sorry`, or `native_decide` proofs.

## Mathematical claim

Let `Q` be quote-currency minor units available and `B` base-currency minor units available. For positive coprime numerator `n` and denominator `d`, an exact candidate pair `(q,b)` is defined by

`q ≤ Q`, `b ≤ B`, and **`n*b = d*q`**.

The proof does **not** assume that candidates already have the form `(k*n,k*d)`. It derives that characterization from coprimality in `exact_iff_common_multiplier`. The proposed multiplier `min(B/d,Q/n)` is then proved to dominate every feasible exact integer pair, independently in both coordinates. Positivity of `n,d` and reduced representation are indispensable premises.

The theorem bank covers:

- Canonical reduced-rate uniqueness under cross multiplication.
- Bounded reductions, nonnegative residuals, and conservation separately in quote and base minor units.
- Equality of residuals interpreted in integers, excluding hidden natural-number subtraction underflow.
- Maximum exact offset over **all** integer-valued feasible pairs; any larger coordinate violates feasibility or exactness.
- Zero multiplier if and only if no positive exact feasible pair exists.
- Exhaustion of at least one exact rate quantum; base reductions divisible by `d`, quote reductions divisible by `n`.
- Reduction bounds at the implementation limit `9_007_199_254_740_991`.
- Failure of quote-currency conservation when a positive base reduction is improperly added to its total.
- Full preservation of both ordered asserted source records; independent IDs, revisions, currencies and reduction rows.
- Refusal of changed rows/source snapshots, expired sources, stale/future agreements, noncanonical rates, same-currency requests and zero exact offsets.
- Direct `propose`-success corollaries for exactness, maximality, conservation and explicit absence of admitted/authenticated/discharge/accounting/payment/FX/legal-approval effects.

## Formalization boundary

`Source`, `Agreement` and `Request` are **host-asserted** records. They have no verified provenance, signature, authority epoch, current-source database or contract interpreter. The `SourceAssertions` predicate abstracts the Elixir public-ID grammar, ISO-shaped currency regex, reference byte-length caps and dynamic-map shape checks. Those implementation boundaries are covered separately by Elixir acceptance tests. Typed natural numbers rule out negative or fractional values in Lean; the Elixir layer must reject such inputs before correspondence applies.

`assemble` retains ordered quote and base rows. The implementation's separately sorted `totals_by_currency` list and exact serialized terms hash require the comparison/Elixir tests. This model does not prove hash collision resistance, serialization injectivity, authenticity of an evidence reference, or source history freshness.

A mismatched old revision/row is rejected by recomputation. A freshly supplied, internally consistent **fabricated** source record can still generate an internally consistent preview. Recomputing a self-contained preview is not an independent source-history check. Likewise, agreement timestamps are asserted freshness fields, not authenticated proof of a live contract. `verifyPlan` exactly compares the entire recomputed preview, including observation time; unchanged old previews fail at a changed observation time.

Arithmetic correctness does not establish authenticated contractual authority, effective debt discharge, accounting recognition, a favorable legal classification, or authorization to execute payments or foreign exchange. The model intentionally supplies no settlement transition.

## Direct reproduction

From this directory, with the pinned Lean binaries on `PATH`:

```sh
lean -o CrossCurrencySetoff.olean CrossCurrencySetoff.lean
LEAN_PATH=. lean Contracts.lean
LEAN_PATH=. lean AxiomAudit.lean
LEAN_PATH=. lean --run Eval.lean < arithmetic-input.tsv
```

The repository-level verification runner uses fresh temporary build directories, audits the complete declaration inventory, runs adversarial proof controls, and compares outputs against the independent Quint model and actual Elixir module.

The evaluator reads `Q<TAB>B<TAB>n<TAB>d` and emits `status<TAB>quoteReduction<TAB>baseReduction<TAB>quoteResidual<TAB>baseResidual`. Status `0` means invalid source amount/rate, `1` means no positive exact offset, and `2` means accepted. Invalid/no-offset rows emit zero reductions with both original residuals. All four numeric inputs must be at most the implementation bound; source amounts must be positive and the rate must be canonical. Core arithmetic theorems also cover zero available amounts.

The development container had a procfs/PID namespace mismatch: Lean's own `/proc/<pid>/exe` lookup failed although `/proc/self/exe` was available. Local compiler invocations used a narrow, separately recorded `readlink` compatibility adapter mapping only that self-executable path. The stock Lean compiler/kernel and libraries were unchanged. Hosted runs should execute without this container-specific adapter.
