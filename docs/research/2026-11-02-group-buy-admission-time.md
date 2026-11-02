# Group-buy admission-time investigation — issue #251

## Conclusion

The authority acceptance test assumed its outer seller admission would still
be in the appender's current second after signing and submission. That is
stronger than the implemented contract. Holding the final admission past its
signed second reproduces the reported `{:error, {:reject, 0,
:stale_admission_time}}` on **both** historical revisions. The same revisions
pass without the injected delay. This confirms a timing-sensitive test defect;
it does not establish a production authorization or persistence defect.

The historical failure contains neither the signed timestamp nor the
appender's sampled second. Consequently, the precise scheduling of that old
run cannot be recovered: a boundary crossing is a reproduced sufficient cause,
not a claim to have observed its clock directly.

## Historical evidence and comparison

| Evidence | Revision / seed | Result |
| --- | --- | --- |
| [Consolidation 41335287945](https://github.com/larsbx/biz-kit/actions/runs/41335287945), job 124933704854 | `5821fa8e4a189dd336c1791bafeb8a25a6fc0c26` / `61024` | Common ledger failed at the final success assertion in `malformed and foreign consents fail without killing the appender`: `:stale_admission_time`. |
| [Consolidation 41360754605](https://github.com/larsbx/biz-kit/actions/runs/41360754605), job 125010399684 | `c3220da4b3a7a087bccbe16f0dfb17f2115a3e29` / `307695` | Ledger and orchestration job succeeded. |
| Local, original first revision, isolated reported test | `5821fa8e…` / `61024` | 1 test, 0 failures, 13 excluded. |
| Local, original first revision, full authority module | `5821fa8e…` / `61024` | 14 tests, 0 failures. |
| Local, original later revision, full authority module | `c3220da4…` / `307695` | 14 tests, 0 failures. |
| Local, first revision, final admission held across its signed second | `5821fa8e…` / `61024` | 1 test, 1 expected failure, 13 excluded; exact reported rejection. |
| Local, later revision, identical boundary injection | `c3220da4…` / `307695` | 1 test, 1 expected failure, 13 excluded; exact reported rejection. |

The historical workflow's ledger step runs `mix test` in
`apps/coop_substrate`, with `MIX_ENV=test`, PostgreSQL 16, OTP 27.3.4 and
Elixir 1.19.0. Local reproductions used OTP 27.3.4, Elixir 1.19.0 and
PostgreSQL 16.15, the unchanged test aliases/configuration, the locked
dependencies and the respective recorded seeds. Local PostgreSQL ran directly
rather than in the Actions service container. Focused runs select the module
or reported test instead of recreating every preceding Consolidation step.

The checkout logs actually identify PR merge commits
`89101423545e5f1a0e12268bfaa7def889de8c39` and
`9a435341036dd364861926bb8e8ef7711734db82`. Their trees are respectively
`d37b84d8a25289dc4e6982eedb5e5ad24f384155` and
`6daef2053ad3ffb1c1c685c8e84c67d6b6a2d49d`, exactly equal to the associated
PR head trees used locally. Thus the local head reproductions use the same
complete source trees as the historical workflow checkouts, not merely the
same authority file. Both historical ledger runs contained 1 doctest,
20 properties and 649 tests; the first had 1 failure and the later had none.

`git diff 5821fa8e… c3220da4… --` produces no differences for the authority
test, `GroupBuys`, `Log`, `Membership`, `BindingRound`, substrate test config
or Consolidation workflow. The later green run therefore did not introduce a
fix to this path.

## Contract and state trace

1. `GroupBuys.acceptance/2` verifies the original buyer consent, embeds its
   full canonical signed record and samples the host's millisecond clock for
   a new outer envelope. The caller then signs that envelope as the seller.
2. `Log` verifies the signed batch, guard and duplicate status. For a new
   batch, `verify_validity/2` calls `GroupBuys.live_check/2` in the serialized
   appender. For a binding admission, it requires
   `div(env.timestamp_ms, 1000) == current_host_second`. Signing, scheduling or
   queueing can cross that boundary even with no intervening accepted event.
3. Live checks validate current authority and deadlines. Deterministic
   validity/folding uses the signed envelope's second. The equality check is
   what makes the admitted binding transition use the same second as replay.
4. There is **no accepted-time watermark in this path**. The ledger head is a
   sequence/hash, and round state has version, pledges, activation and seen
   commands. Earlier milliseconds in the same current second remain valid;
   past and future seconds are both rejected as stale.
5. Failed single events return the original GenServer state. Batch validation
   may calculate provisional gate folds, but discards them if any event fails;
   `assign_chains`, encoding, persistence, links, publication and committed gate
   replacement follow successful validation. Rejection consumes no ledger
   position, event ID, consent ID, round version or authority state.

The old `submit_consent/3` helper already compensated for a boundary by
rebuilding and seller-signing only the outer admission, at most three retries.
The reported final assertion called `submit(admission(...))` directly.
Replacing only that assertion with the helper would reduce its failure rate
but leave every direct negative assertion exposed to the same clock race and
would not prove rejection is a no-op.

## Change

`GroupBuys` now has a compile-time clock dependency, defaulting to `System`.
Only test configuration selects `CoopSubstrate.GroupBuyClock`, a module in
`test/support` that delegates to `System` unless a supervised fixture is
running. The authority and escrow-admission modules are synchronous and install
a fixed `.999` instant before setup. Their signed-event builders, admission
builder, provider reports and live appender share that clock. The fixture is
stopped by ExUnit; other suites retain real-clock behavior. No request can
select the trusted clock, and no
new admission argument accepts a caller-provided current time.

The timestamp equality check, signature checks, buyer consent bytes,
authorization, expiry, binding and financial semantics are unchanged. The
test-only retry helper becomes a direct submit; the offer-expiry test advances
the clock to its exact deadline instead of sleeping.

Regressions now establish:

- A one-millisecond advance from `.999` to the next second rejects an otherwise
  valid signed admission, preserving head, full gate, stored events and chains.
- Editing the signed timestamp without a new seller signature fails verification.
- A fresh seller signature over the unchanged buyer consent can reuse the
  rejected outer ID and commit exactly one event; recovery and replay agree.
- Both past and future seconds reject; earlier milliseconds within the current
  second do not imply a watermark violation.
- A valid first event followed by a malformed second event leaves the entire
  batch unapplied; the first consent can then be admitted normally.
- Refreshing the outer admission cannot renew expired buyer authority.
- Existing malformed/foreign rejection checks compare the entire gate and
  durable event list as well as the head, before a direct successful admission.

## Reproduction

For an original revision, create a detached worktree at either full SHA above,
install its locked dependencies and run, from `apps/coop_substrate`:

```sh
MIX_ENV=test mix test test/group_buy_authority_test.exs --seed 61024
# Use --seed 307695 for c3220da4… .
```

To reproduce the original assertion failure, replace **only** the last two
lines of the malformed/foreign test temporarily:

```elixir
rejected(env, :consent_scope_or_policy_mismatch)
event = admission(ctx, original)
next_second = (div(event.timestamp_ms, 1000) + 1) * 1000
Process.sleep(max(next_second - System.system_time(:millisecond), 0) + 10)
assert {:ok, _} = GroupBuys.submit(event)
```

Then run `mix test test/group_buy_authority_test.exs:503 --seed 61024` (or
the later seed). Expected result: the named test fails with
`{:error, {:reject, 0, :stale_admission_time}}`. Restore the file afterwards.
This historical injection intentionally uses the wall clock; committed
regressions use the deterministic fixture and contain no boundary sleeps.

For the corrected revision, from `apps/coop_substrate`:

```sh
MIX_ENV=test mix format --check-formatted lib/coop_substrate/group_buys.ex config/test.exs test/group_buy_authority_test.exs test/group_buy_escrow_admission_test.exs test/support/group_buy_clock.ex
MIX_ENV=test mix test test/group_buy_authority_test.exs test/group_buy_escrow_admission_test.exs --seed 61024
MIX_ENV=test mix test test/group_buy_authority_test.exs test/group_buy_escrow_admission_test.exs --seed 307695
MIX_ENV=test mix test --seed 61024
```

## Corrected-revision validation

The patch was first validated on main `27682a2f…`, then rebased cleanly onto
`30bf1e1ae7470420eafa8a4ffb16e6cc1948ba54` after inventory reconciliation
was strengthened in PR #256. The full ledger, authority module (seed
`307695`) and inventory suite were rerun on that base. That full-ledger run
exposed another instance of the timing defect: the escrow test `unfunded
binding cannot reserve stock, and rejected holds never change canonical head`
expected `:stale_stock_version` but received `:stale_admission_time`. It still
used the real clock. The same deterministic fixture was therefore applied to
the escrow module as well, and both group-buy modules and the full ledger were
rerun after that correction. No stock, escrow or authorization rule was changed.

| Local check | Result |
| --- | --- |
| Changed Elixir files, `mix format --check-formatted` | Passed. |
| Authority module, seed `61024`, max_cases 8 | 18 tests, 0 failures. |
| Authority module, seed `307695`, max_cases 8 | 18 tests, 0 failures. |
| Authority + escrow-admission modules, seed `61024` | 41 tests, 0 failures. |
| Authority + escrow-admission modules, seed `307695` | 41 tests, 0 failures. |
| Full common ledger, seed `61024`, max_cases 8 | 1 doctest, 20 properties, 653 tests, 0 failures, no invalid tests. |
| GroupBuyCore, seed `61024` | 51 tests, 0 failures. |
| InventoryCore, seed `61024`, after rebase | 2 properties, 29 tests, 0 failures. |
| Substrate `mix compile --warnings-as-errors` | Exit 0. |
| `git diff --check` | Passed. |

An initial full-ledger attempt invalidated five signed replay tests because
`psql` was absent from PATH. After exposing the PostgreSQL 16 client, the
complete suite above passed without exclusions or invalid tests. Existing
fault-injection and logger formatter messages appeared in the ledger output;
their presence was not treated as a test failure or as causal evidence for
this issue. Full Consolidation workflow acceptance remains separate from
these local checks; no claim is made here that unrelated workflow jobs ran
locally.
