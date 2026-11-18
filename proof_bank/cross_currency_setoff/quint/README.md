# Independent bounded Quint setoff oracle

`ExactSetoff.qnt` searches every candidate integer pair `(quote, base)` in the
two available-amount ranges, keeps pairs satisfying `quote * d = base * n`, and
chooses the pair with greatest base reduction. It does not copy the Elixir
division algorithm. The exhaustive test checks 2,916 input tuples:
`Q,B ∈ {0,…,8}`, `n,d ∈ {0,…,5}`. Every candidate reduction pair for each tuple is
also enumerated. This is deterministic finite enumeration in the Quint 0.33.1
TypeScript evaluator, **not** an unbounded proof or an Apalache result.

The model separately checks conservation in each denomination, maximality of
both reductions, nonnegative residuals, exact cross multiplication, refusal of
noncanonical or nonpositive rates, and absence of positive feasible pairs when
an exact offset is refused. Nine named tests include source identity/revision,
reciprocity, stale/future agreements, source substitution, changed agreements,
rounding attempts, and scalar currency aggregation. Eight actual source mutants
must typecheck and then fail a named behavioral assertion.

The source and authority model uses finite integer labels for IDs, currencies,
references and parties. It checks equality and nonzero validity representatives;
it does not prove the Elixir string grammar, exact record shape or cryptographic
encoding. `commitmentPreimage` is a transparent copy of the structured terms,
not SHA-256. Length-prefixed encoding and digest comparisons belong to the
Elixir harness. Hash collision resistance is not proved here.

`verify` deliberately recomputes from the candidate's own assertions, matching
the implementation's trust boundary. An old candidate with a changed field is
rejected, but a fully recomputed preview with a different source ID, revision or
agreement reference is accepted if its assertions are internally valid. The
model does not claim latest-source authentication, a signature, contractual
authority, debt discharge, accounting recognition or payment/FX execution.

## Run

```sh
QUINT_CLI=quint python3 proof_bank/cross_currency_setoff/quint/check.py \
  --out-dir /tmp/setoff-quint-evidence

printf '8\t8\t3\t2\n1\t1\t3\t2\n' | \
  QUINT_CLI=quint python3 proof_bank/cross_currency_setoff/quint/evaluate.py
```

The first command requires Quint 0.33.1 and emits a JSON receipt after the
baseline and all eight behavioral mutation controls finish. The second emits
one TSV output row per input. Status codes are 0 (invalid/noncanonical), 1 (no
positive exact pair), and 2 (accepted). Output columns are status, quote
reduction, base reduction, quote residual, base residual. Rejected rows have
zero reductions and preserve both supplied amounts. The batch wrapper refuses
inputs outside its declared finite profile, so a large-number boundary cannot
accidentally start an unbounded enumeration.
