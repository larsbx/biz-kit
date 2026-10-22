# v1 conformance correction after PR #63

This correction preserves the Elixir implementation's behavior and every existing
test assertion. It resolves the four review findings on PR #63:

- C1 and §1.3 distinguish recognized, constructible primitive records from
  invariant-valid organizations. Negative fixtures reach the checker; duplicate
  ids and unsupported primitive sorts remain construction errors.
- C4 and §6 compare non-cycle diagnostics exactly. Cycle choice is traversal
  dependent: conformance requires valid directed witnesses and agreement on
  existence for each invariant at each epoch, then compares the aggregate by
  name and earliest occurrence. Raw checker deduplication is unchanged.
- C5 and §7.2 specify all public ownership success/error wrappers, structured
  insufficient-holdings reasons, record fields and the `price:` option.
- §8 specifies cooperative keyword options, the nested `capital:` map and its
  default, worker forwarding, and partnership options.

`test/conformance_test.exs` adds five translated-port regression cases, including
construction via all three entry points, cooperative defaults and unequal capital,
exact ownership variants, all four cycle invariants, multiple cycles, self-loops,
epoch changes, and rejection of empty/open/non-edge witnesses. Existing tests
continue to cover the remaining ownership errors and invariant details.

The Consolidation workflow now runs `mix test` in `apps/keel` and checks formatting
of the changed Elixir files. The ordinary repository validation command is:

```sh
cd apps/keel
MIX_ENV=test mix test
```

Local validation (2026-10-22): **89 tests, 8 properties, 0 failures** on Elixir
1.14.0 / OTP 25, with StreamData 1.4.0 (the version in `mix.lock`, upstream tag
commit `49958c0`). The workspace initially lacked Elixir and umbrella dependencies.
Validation used unmodified copies of Keel's `lib` and `test` directories in a
standalone Mix harness with a path dependency on that StreamData checkout;
protocol consolidation was disabled in the temporary harness to avoid an installed
Hex 2.5.4 / Elixir 1.14 protocol incompatibility. No project dependency or runtime
configuration was changed. The umbrella/database suites were not run locally.
