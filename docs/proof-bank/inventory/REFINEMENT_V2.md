# Inventory I-2: precise restricted correspondence

The initial I-1 model remains available. I-2 adds a machine-checked abstract
state machine and bounded executable correspondence, not a proof of arbitrary
Elixir behavior, physical stock, durable production safety, or host refinement.
Local verification receipt: `63c8e537d39ef7526025d5ff43942c902a8ea273`
(code revision; the later receipt-only commit does not alter executable sources).

Issue: [#248](https://github.com/larsbx/biz-kit/issues/248).

## Partial refinement map α

Fix merchant `merchant`, item `part`, unit `each`. The supported finite domain
has two locations `a`, `b`, with at most one retained reservation per location:
`hold-a` belongs to `a` and `hold-b` to `b`. Other IDs/locations, extra record
fields, invalid metadata, and arbitrary corrupt terms are outside this fragment.
This is a restriction, not an assertion about the full InventoryCore API.

| Concrete Elixir value | Lean `BizKitInventoryLocations` value |
|---|---|
| `locations["a"/"b"]`, absent interpreted as zero | `Stock.onHand false/true : Nat` |
| absent `reservations["hold-a"/"hold-b"]` | `none` at the corresponding Bool index |
| present record with matching location, nonnegative integer remaining and expiry, supported status | `some Reservation(remaining, expires_at_ms, status)` |
| `expiry_watermark : nonnegative integer` | `Stock.watermark : Nat` |
| `version : nonnegative integer` | `Ledger.version : Nat` |
| `seen` map from numeric-string ID to original canonical command | `Ledger.seen`, ordered by accepted history; compare maps at the Elixir boundary |

Only zero-valued absent location entries are identified with explicit zero
entries. Reservation absence is never identified with a closed record. Released
and expired records retain remaining quantity, expiry and identity; fully committed
records have zero remaining. `held(l)` is the active record's remaining quantity,
otherwise zero. Thus within this domain it equals the real sum of active holds.
`Safe` means `held(l) ≤ onHand(l)` separately at both locations; `Positive`
requires every active record to have positive remaining quantity. Outside this
domain α is undefined. The conformance test's projection is applied only to the
reachable states in the generated traces, not used as an untrusted-input parser.

## Command and result map

Commands have numeric-string IDs, nonnegative expected versions and exactly the
fields emitted by the test constructor; unused Lean fields have canonical values
(`quantity=0` for release, `expires=0` except reserve, `location=a` for expire).
The six supported constructors map directly:

| Command | Transition |
|---|---|
| receive(location,q) | positive q increases that location |
| reserve(location,q,expiry) | positive q; expiry above explicit watermark; never overwrite a retained ID; q within local availability |
| commit(reservation,q) | active only; positive q ≤ remaining; subtract q from physical and held quantities; close at zero |
| release(reservation) | active → released, retain remaining quantity |
| transfer(from,q) | target is the other location; positive q within source availability; change both balances |
| expire(at_ms) | refuse clock reversal; active records with expiry ≤ at_ms become expired; set watermark |

Expiration is command-driven, not wall-clock-driven. No automatic expiry is
assumed before commit or reserve. Receive with q=0 is refused. Duplicate
original commands return the *current* state unchanged before checking version.
A changed command under an accepted ID conflicts, even if its version is stale.
Rejected commands do not enter history or advance version and may be corrected
and retried. Unsupported adjustment, dynamic locations/IDs, same-location
transfers, multiple holds at one location, other scopes, arbitrary extra fields,
and negative/noninteger input validation remain outside the formal fragment.
Existing real-core tests continue to cover some of those wider behaviors.

A successful concrete command is compared with `admit` on α(state): outcome,
per-location balances, complete reservation records, watermark, version, and
all original commands in `seen`. Errors compare the exact reason and retain the
prior state. This is **bounded executable correspondence**, not a universal
commuting-diagram theorem for Elixir.

## Checked abstract obligations and executable witnesses

The existing Quint models cover other protocols and contain no InventoryCore
specification. I-2 uses Lean for its inventory machine and oracle; it makes no
additional Quint result claim.

`transition_safe`, `transition_positive`, `admitted_invariants` and
`reachable_invariants` prove local capacity and active-record positivity for
all reachable states of this restricted abstract machine. Separate exact-replay,
changed-replay and version-conflict lemmas cover admission order. These proofs
use no admitted facts, custom axioms, `sorry`, `native_decide`, or external oracle.
Lean's fresh kernel replay and module axiom audit remain acceptance requirements.

`InventoryFixtures.lean` evaluates the **same** `admit` and `transition` functions
and emits 24,064 outcomes in 1,536 traces. Initial quantities are independently
0..3, both reservation requests independently 1..4, both transfer directions,
and commit/release/expiry branches. Traces include partial/full commits,
closed-record refusals, equality-at-expiry, clock reversal, invalid expiry,
capacity refusal, unknown records, old replay after later mutations, altered ID
reuse, and fresh stale versions. This is a structured finite family, not exhaustive
state-space exploration. CI regenerates and byte-compares decompressed TSV before
advertising conformance. Gzip only compresses the checked-in fixtures.

Independent negative controls: Lean exhibits local overselling hidden by global
capacity and the difference between closed and revived holds. The real-core
harness kills three valid-shape mutants by assertion failure: commit fails to
subtract physical stock, release deletes its persistent record, and replay bumps
the version. A crash or parse error does not count as a killed mutant.

## Malformed states and PR #256

PR #256's existing orphan-location regression in `inventory_core_test.exs` is
unchanged. New tests cover zero-sized active holds and negative stock. These
are injected corruptions, not claimed reachable states. The audit also records
that `check/2` raises on some incomplete maps and accepts an incomplete inactive
record. `available/3` and `apply/3` do not automatically reconcile arbitrary
corruption. A total input validator, full structural reconciliation and a proof
of reachability exclusion for all malformed states remain open obligations.

## Actual authority inspected

There **is** an inventory authority path: `CoopSubstrate.GroupBuys.Stock`, reached
through seller-signed `GroupBuyStockCommandAdmittedV1` events and the serialized
`CoopSubstrate.Log`. Its shared key is `{chapter,seller,sku,unit}`, across campaigns.
It supports receive and funded reserve only. Its policy checks live seller keys,
binding terms and escrow coverage before calling the real core. The Log verifies
and folds the whole proposed batch against a temporary gate before persistence,
then publishes and replaces its in-memory gate after the store append succeeds.
The restaurant host handles orders, not general stock admission.

The new `:inventory_refinement` integration cases exercise this real path with
Postgres: equal-version receive contenders admit once; funded reserve contenders
admit one hold; a stale later stock command aborts an otherwise valid batch prefix;
restart recovers the accepted state and rejected commands consume no IDs; a new
envelope cannot repeat an already accepted stock mutation; a pre-signed proposal
submitted after seller authority expires is refused. These are admission-rejection
rollback tests, **not injected persistence-failure or crash-window tests**.

Still unverified: multi-node/multi-appender scheduling, failures after durable
append but before gate publication, durable replay uniqueness for all envelope
variants, current tenant grants for a general inventory host, authoritative
transfer/release/expiry/adjust admission, cross-aggregate basket commit and rollback.
`InventoryCore.Basket.plan/7` remains preflight only; no fake in-memory host stands
in for a durable basket implementation. A complete host contract must define its
writer, scope/authorization lock, expected revisions, uniqueness constraints,
transaction boundary, acknowledgment/recovery rule and fault-injection surface.

## Reproduction and evidence

Use the repository-pinned Lean 4.35.0 and Elixir 1.19 / OTP 27 toolchains:

```sh
bash formal/lean/check.sh
(cd apps/inventory_core && MIX_ENV=test mix test --no-start)
bash scripts/test-group-buy-authority.sh
```

The host script runs the full escrow suite including these tagged checks. To run
only the new cases inside its staged dependency closure, use
`mix test test/group_buy_escrow_admission_test.exs --only inventory_refinement`.
Recorded results are in `proof_bank/inventory/i2-evidence.json` and exact-head PR
checks; a passing abstract theorem never automatically promotes runtime conformance.

Local acceptance passed: pinned Lean build, all fresh kernel replays, fixture
equality, all-module axiom audit (246 declarations in the new module), 34 core
tests plus two properties, and 26 escrow-admission tests including all three new
host cases. Publication is authorized; hosted acceptance is pending the published
revision's workflows. See the evidence JSON for exact code revision, source blob
hashes, log digests, toolchain details and the local sandbox compatibility note.
