# SCF formal coverage

`BizKitScf.obligation` is the coverage entry for `scf_core`. It is a theorem
about an unbounded pure Lean model, with separate theorems for the ledger and
statement equations. It is not a refinement or runtime conformance result for
the Elixir implementation.

## Source and obligation

The inspected source revision is
`a9a1bd1b35055b749181c0797f081c9297118a23`. Its SCF source is unchanged from
`c0bd321e131965597668b164fe55fc0a46c86a5d`.

The catalog's first obligation is:

> Establish that every reachable ledger preserves debit-credit equality and
> closed-period entries under posting, closure and reversal, with exact-retry
> idempotence and an explicit contract for when a reversal cancels the original.
> Establish separately that statement projections preserve their equations over
> the admitted account domain.

Relevant source blobs at the inspected revision:

| Source | Git blob |
| --- | --- |
| `apps/scf_core/lib/scf_core/chart.ex` | `3d2090183387cd83db88fb2b53062c7b80b7aac9` |
| `apps/scf_core/lib/scf_core/entry.ex` | `765f244e718cf72240e72047af9ae29bbc2c8a34` |
| `apps/scf_core/lib/scf_core/ledger.ex` | `1ef284eb8f4774daf5b0182c295d5fdab5381382` |
| `apps/scf_core/lib/scf_core/statements.ex` | `86b024910166bbc1e5dc3e6da61e3bbcde0d5916` |

## Checked model contract

| Catalog clause | Lean declaration | Scope and premises |
| --- | --- | --- |
| Reachable debit-credit equality | `reachable_safe`, `reachable_balanced` | Induction over arbitrarily many successful `post`, `close`, and `reverse` steps from the empty ledger. Every stored entry has at least two positive lines and equal integer debit/credit totals. |
| Closed-period preservation | `step_preserves`, `PreservesClosed` | Every successful transition from a reachable ledger preserves every prefix through or before its previous closure date. Closure dates cannot decrease. Exact retries preserve the whole ledger. |
| Exact-retry idempotence | `exact_retry` | A validated entry exactly equal to the entry stored under its ID returns the original ledger, including after period closure. A changed metadata value is a conflicting retry. |
| Reversal cancellation | `reversal_contract`, `swapped_movement` | The original exists and is admitted; the reversal ID is fresh; its date is open; no caller line override is supplied. Reversal is admitted and subtracts the original movement at every account. |
| Income statement | `income_equation`, `chart_partition` | Each admitted account belongs to exactly one modeled chart group. The source's intermediate income formula equals products minus expenses. |
| Balance sheet | `tiers_partition`, `balance_sheet_equation` | Input amounts are signed balances per account. The trial balance sums to zero. Class 4/5 balances are split by sign; current result is included in capital. Total assets equal total liabilities. |

The model retains `Ledger.reverse/3`'s caller override of generated lines.
`override_does_not_cancel` proves a balanced override is accepted yet fails
cancellation. `repeated_reversal_counterexample` proves that two distinct fresh
IDs can reverse one original twice. Neither behavior has been changed or
reclassified as an implementation regression by this coverage repair.

The theorem's no-override premise is sufficient, not necessary: supplying the
exact same swapped lines explicitly would also cancel the original. A reversal
date after closure may leave the original closed period unchanged while the
original and reversal cancel over an interval containing both dates. No claim
is made about cancellation in a date window containing only one of them.

## Admitted account partition

`Account.bucket` represents the following source groups; `subaccount` is an
opaque identity component. No theorem equates that representation to the
Elixir string parser.

| Model bucket | Admitted source account prefixes |
| --- | --- |
| `capital` | 10, 11, 12 |
| `debt` | 13, 15, 16, 17, 18 |
| `asset` | Class 2: 20, 21, 22, 23, 26, 27, 28, 29 |
| `stock` | Class 3: 30–39 |
| `tiers` | Class 4: 40–49; class 5: 50, 51, 52, 53, 54, 58, 59 |
| `c60` through `c69` | Class 6: 60–69, individually |
| `p70`, `p72` through `p78` | Class 7: 70, 72, 73, 74, 75, 76, 77, 78, individually |

The source's bilan selector includes 14, but the chart does not admit it. There
are no admitted 71 or 79 accounts. Subaccounts inherit their admitted prefix.
The proof deliberately does not add those missing prefixes to the domain.

## Witnesses and controls

The following are kernel-checked theorems in the same compiled module:

- `nonvacuity_witness`: post an opening entry, close its period, retry it
  exactly, then reverse it on a later date with a fresh ID.
- `closed_period_refused`, `conflicting_retry_refused`, and
  `closure_regression_refused`: reject a new closed-period entry, a changed
  same-ID entry, and a decreasing closure date.
- `unchecked_post_counterexample` and `unchecked_balance_counterexample`:
  demonstrate the violations admitted by bypassing the corresponding guard.
- `override_does_not_cancel` and `repeated_reversal_counterexample`: expose
  limits of the reversal contract.
- `missing_result_counterexample`: a balanced bank/sales example fails the
  bilan equation when current result is omitted from liabilities.

## Reproduction and acceptance

Use the checksum-pinned Lean 4.35.0 installation required by `lean-toolchain`.
The module is registered in the default Lake targets, fresh kernel replay, and
the module-wide allowed-axiom audit in `check.sh`.

```sh
python3 -I -m unittest discover -s scripts/tests -p 'test_formal_coverage_audit.py' -v
python3 -I scripts/formal_coverage_audit.py --base-ref a9a1bd1b35055b749181c0797f081c9297118a23
bash formal/lean/check.sh
```

For an isolated SCF compile and kernel replay:

```sh
cd formal/lean
lake build BizKitScf
lake env leanchecker --fresh --verbose BizKitScf
```

Those two commands do not substitute for `check.sh`'s all-module axiom audit.
The registry audit establishes registration consistency; the Lean gate must
also pass before this is accepted as checked coverage. Neither command proves
the implementation refinement left open by the catalog.

The next implementation proof milestone is a source-pinned correspondence for
Elixir `Entry.new/1`, `Ledger.post/2`, `close/2`, and `reverse/3`, followed by
the account-parser and per-account balance-extraction correspondence needed to
instantiate the statement theorems. A single-correction admission policy, if
desired, needs an explicit owner-approved contract and implementation change.
The characterization catalog's review and conformance statuses are unchanged.
