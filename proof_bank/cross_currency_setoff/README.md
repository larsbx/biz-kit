# Exact-rational bilateral setoff preview: proof and comparison bank

This package verifies the pure, unsigned preview introduced in draft PR #341.
It does not activate settlement or make a legal determination. Both source
obligations and all authority references remain unverified host assertions.

## Arithmetic contract

Let `Q` be available quote-currency minor units, `B` available base-currency
minor units, and `n/d` a **positive coprime** rational number of quote minor
units per base minor unit. The implementation computes

```
k = min(B / d, Q / n)       # natural-number integer division
q = k * n                  # proposed quote reduction
b = k * d                  # proposed base reduction
quoteResidual = Q - q
baseResidual = B - b
```

The Lean proof establishes that every exact integer pair satisfying `n*b=d*q`
has the form `(q,b)=(k*n,k*d)` when `gcd(n,d)=1`. The maximum theorem ranges
over **all exact integer pairs within the two balances**, so the implementation
does not obtain its maximality claim by assuming its own algorithm's shape.
Conservation and nonnegative residuals hold separately in each currency. An
integer interpretation of residuals prevents natural-number truncation from
concealing underflow. If `k=0`, no positive feasible exact pair exists.

The rate must already be reduced; the preview does not silently normalize a
different representation. Lean also proves uniqueness of reduced positive
representations. Numeric bounds are checked by the Elixir adapter; the core
arithmetic theorems quantify over arbitrary natural numbers.

## Three executable views

| Artifact | Role | Scope |
|---|---|---|
| `lean/CrossCurrencySetoff.lean` | 40 universal kernel-checked arithmetic and asserted-record theorems | Exactness, maximality, canonicality, conservation, source preservation and inert effects |
| `lean/Contracts.lean` and `proof_targets.json` | Independently restated theorem types and complete registered inventory | Missing or weakened targets cannot be counted merely by theorem name |
| `lean/AxiomAudit.lean` | Transitive axiom inspection | Only Lean's standard `propext`, `Quot.sound`, `Classical.choice` are permitted |
| `quint/ExactSetoff.qnt` | Independent finite oracle | Enumerates feasible integer pairs by cross multiplication; no quotient algorithm |
| `elixir/evaluate.exs` | Execute the actual `BarterCore.CrossCurrencySetoff` source | Compare results and check observable source/effect fields |
| `tools/verify.py` | Rebuild, compare, mutate and fingerprint | Records head, dirty state, source hashes, tool identities and logs |

The Quint arithmetic domain contains **2,916 input tuples**:
`Q,B in 0..8`, `n,d in 0..5`. Each tuple searches all feasible integer reduction
pairs in its available balances. The nine named Quint tests additionally cover
source identity, revised assertions, agreement timing and tampering. Those
source tests are finite fixtures, **not** an exhaustive protocol state-space
exploration. The runner uses the TypeScript evaluator; no Apalache result is
claimed.

All 2,916 arithmetic tuples are compared across Lean, actual Quint execution and
the real Elixir source. A separate deterministic corpus of **992 tuples** checks
large integer boundaries and seeded large inputs in Lean and Elixir. The bounded Quint oracle
refuses inputs outside its declared profile. Error rows in the comparison
protocol represent a test projection `(status,0,0,Q,B)`, not a preview object
returned by the public Elixir API.

## Adversarial controls

The runner executes altered Elixir programs that remove rate canonicality,
replace the limiting minimum by a maximum, invert the rate direction, add a
rounded quote unit, or corrupt residual accounting. These programs must execute
successfully but disagree with the baseline corpus; a startup/syntax failure
does not count as detecting an arithmetic mutation.

Five further Elixir mutations omit source IDs/revisions from commitment terms,
accept an expired agreement, bypass full-candidate equality, or discard the
second currency total. The 19 dedicated cross-currency ExUnit tests must execute
and reject each altered program through failing assertions.

Eight altered Quint sources must typecheck and fail the intended named
behavioral assertion. They cover canonicality, the maximum, rate direction,
rounding, source revision loss, expired agreements, aggregated currencies and
omitted candidate equality. Lean controls require rejection of a false rounding
proof, a custom-axiom dependency and an anonymous contract placeholder. Positive
Lean compilation treats warnings as errors. The formal contract file checks
theorem types separately from the implementation proofs. Six evidence-gate
tests reject missing/extra axiom results, unauthorized axioms, ignored-source
injection, modified source bytes and false arithmetic observations.

The ExUnit tests also exercise both source identities, source revisions, source
substitution, stale and future agreements, invalid/nonnumeric/out-of-bound
amounts, integer limits, UTF-8 and colon-containing reference framing, rounded
but numerically conserved output, reordered rows and mixed-currency aggregation.

## Authority and verification boundary

These are five distinct claims:

| Claim | What this package establishes |
|---|---|
| Mathematical correctness | Universal Lean theorems; bounded independent comparison; executable controls |
| Authenticated contractual authority | **Unverified.** References and eligibility are assertions, not signed evidence |
| Effective debt discharge | **Not performed or proved.** The preview creates no admitted business event |
| Accounting recognition | **Not performed or proved.** No journal is posted or functional-currency valuation authorized |
| Payment / foreign-exchange activity | **Not executed.** No settlement capability is activated and classification stays undetermined |

`verify_plan/2` recomputes from the candidate's own asserted inputs and compares
the entire result. Editing an existing candidate without rebuilding it fails.
A freshly recomputed candidate containing a new source revision, substituted
source or fabricated but well-shaped evidence can succeed. The tests preserve
that fact as a positive control: self-consistency is not authentication of an
external contract or current source history. Passing an observation time one
second later also rejects an old candidate, because the observation time is
part of the full result, even when all asserted expiries are still in the future.

The Lean record guard abstracts public-ID parsing, currency-code syntax, map
shape and string byte limits. Those details remain runtime tests, not universal
Lean claims. Quint represents commitment terms structurally; neither formal
model proves the byte serializer injective or SHA-256 collision resistance.
The Elixir tests check concrete framing/tamper examples only. Issue #299 remains
open and is not resolved by this proof bank.

## Reproduce

Use a clean checkout of the exact revision being assessed. Install Elixir
1.19.0 / OTP27, Node, Python3, and the existing checksum-pinned Lean distribution:

```bash
bash formal/lean/install-toolchain.sh /tmp/setoff-lean
npm ci --ignore-scripts --no-audit --no-fund --prefix proof_bank/cross_currency_setoff/tooling/quint
python3 -I proof_bank/cross_currency_setoff/tools/verify.py \
  --expected-head "$(git rev-parse HEAD)" \
  --lean-bin /tmp/setoff-lean/bin/lean \
  --quint-cli "$PWD/proof_bank/cross_currency_setoff/tooling/quint/node_modules/.bin/quint" \
  --elixir-bin "$(command -v elixir)" \
  --output /tmp/setoff-evidence
```

The output directory must be new. `--allow-dirty` is for development and labels
the receipt accordingly; it is not clean-head acceptance. A fresh build and
fresh Lean kernel replay are required. The latter reruns Lean's own kernel,
not a different kernel implementation. Logs, full input/output corpora, source
digests, tool identities and mutation counts are retained in the receipt's
directory. Every scoped source file must match its actual `HEAD` blob, including
files ignored by ordinary Git-status checks. Mix uses a new build directory, and
the suite gate requires all 55 tests with no skipped/excluded tests. The receipt
fingerprints runtime entrypoints and Lean's shared library; the entire tool
library closure and operating system remain trusted. Receipts are unsigned
observations of the stated runner.

On the hosted workflow, checkout explicitly uses the PR's head SHA, rather than
GitHub's synthetic merge. The workflow pins Lean4.35.0 by archive SHA-256,
Quint0.33.1 by committed npm lock, Elixir1.19.0 and OTP27.3.4.19. Normal hosted
execution needs no application-path adapter. A sandbox with an inconsistent
`/proc/<pid>/exe` namespace may require an explicit locally reviewed
`--app-path-adapter`; the receipt fingerprints it rather than silently treating
that run as the normal hosted environment.

For that specific startup issue, the narrowly scoped adapter source is supplied
as `tools/proc_exe_compat.c`. Compile it with the command in that file and pass the
result explicitly; it changes only a process's self-executable path lookup.

## Separate formatter investigation

Original PR-associated Barter run `42520041693` passed 48 tests, then failed
formatting in the two new cross-currency files. Commercial run `42520041628`
passed the same pure tests, then failed formatting; its signed-ledger job failed
formatting in four existing `commercial_setoff_proof` / `commercial_setoff_sources`
files before running the signed tests. `42520041584` was a successful Eatsbot
workflow, not the commercial workflow.

Those original jobs checked out synthetic merge
`6da1cd5525c3faccd0f52e3971a0c27d217c520d`, associated with PR head
`cdf942ec8a30e8b6164438ef384a3d170891dda6`. They are not direct execution receipts
for that head. The six formatter repairs are checked against the original head
by `elixir/format_only.exs`, which compares parsed ASTs with source-position
metadata stripped. Signed-ledger/PostgreSQL tests remain a separate workflow
gate and are not inferred from this pure proof package.
