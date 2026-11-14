# Exact-rational bilateral setoff preview: proof and comparison bank

This package verifies the pure, unsigned preview introduced in PR #341.
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
| `lean/Contracts.lean` and `proof_targets.json` | 40 independently restated, named proposition contracts alongside the 40 model targets | Missing or weakened targets cannot be counted merely by theorem name; contract dependencies are audited too |
| `lean/AxiomAudit.lean` | Transitive axiom inspection of all 80 declarations | Only Lean's standard `propext`, `Quot.sound`, `Classical.choice` are permitted |
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
second currency total. The dedicated cross-currency ExUnit tests first pass
through the same direct-Elixir invocation used for the mutants. A structured
receipt requires the same complete test identities and lifecycle for each run.
Each mutation must then fail its named, relevant assertion; unrelated failures,
missing/skipped tests and non-assertion exceptions cannot count as detection.
The current baseline contains 19 tests, with its actual inventory retained.

Eight altered Quint sources must typecheck and fail the intended named
behavioral assertion. They cover canonicality, the maximum, rate direction,
rounding, source revision loss, expired agreements, aggregated currencies and
omitted candidate equality. Lean controls require rejection of a false rounding
proof, a custom-axiom dependency and an anonymous contract placeholder. Two
further controls weaken an actual model target and then try to bypass its
independent expected proposition with a custom axiom. The first fails type
checking; the second compiles but must fail the contract's transitive axiom
audit. These controls use isolated module search paths and fresh compiled files.
Positive Lean compilation treats warnings as errors, and both the model and
contract modules undergo fresh replay with Lean's own kernel.

Evidence-gate tests reject incomplete/extra axiom inventories, unauthorized
axioms, ignored-source and optional configuration injection, hidden changes to
tracked configuration, false arithmetic observations, incomplete test
lifecycles and unrelated mutation failures. Development-mode receipts cannot
claim clean-head acceptance even when ordinary Git status is clean. Local
Python helpers are compiled directly from the inventoried source bytes, so a
timestamp-valid ignored bytecode cache cannot substitute different helper code.

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

The output directory must be new. `--allow-dirty` always records
`verification_mode: development`, `head_sources_verified: false` and
`clean_checkout: false`; `git_status_clean` separately describes ordinary Git
status. A development run cannot claim clean-head acceptance. A fresh build and
fresh Lean kernel replay are required. The latter reruns Lean's own kernel,
not a different kernel implementation. Logs, full input/output corpora, source
digests, tool identities and mutation counts are retained in the receipt's
directory. Every scoped source file must match its actual `HEAD` blob, including
files ignored by ordinary Git-status checks. The manifest includes recursive
root and application configuration trees and formatter inputs, including
optional app config files that the umbrella imports when present. Workflow path
filters include these configuration and verification inputs. Mix uses a new
build directory, and its structured suite receipt requires every declared test
in every current test file to start and pass once, without skipped/excluded
tests; the total is recorded rather than fixed to a historical count. The receipt
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
metadata stripped. It permits the later, exact correction from
`length(ctx.proof.commitment)` to `byte_size(ctx.proof.commitment)` in the named
proof test only; its negative controls reject broader AST changes.
Signed-ledger/PostgreSQL tests remain a separate workflow gate and are not
inferred from this pure proof package.

## Verification-gate review, 2026-11-14

The original formal workflow [42602931281](https://github.com/larsbx/biz-kit/actions/runs/42602931281)
completed all 31 then-current stages at `4fc57384b0de29c2d84e853d1670d35a9d38368d`.
That historical result is distinct from execution of a newer checkout. The
original arithmetic proofs and actual offset implementation were left unchanged
by this gate review.

Three isolated controls demonstrated gaps in the former evidence gate: a
weakened model target could be masked by an unaudited contract axiom; an ignored
optional app config file could be absent from the source manifest; and a generic
unrelated assertion could satisfy the old mutation-summary regex. The named
contract audit, broader source inventory and test-specific mutation receipts
close those observed gaps. Additional corrections label development mode
unconditionally and prevent local helper bytecode substitution. These changes
strengthen verification evidence; they do not expand contractual authority or
activate a business effect.
