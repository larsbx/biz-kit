# Atomic native-session restoration and revocation

2026-10-22. Focused correction to the first P1 in the
[security and validation gate](../roadmap.md#security-and-validation-gate-2026-10-22-audit)
introduced by PR #64. Baseline: main `c4fb5f1` (includes #64 and #65).

## Ordering and durability

The cluster's `Sessions` singleton serializes native creation and revocation.
Native creation writes the durable row before inserting the ETS entry, within
one call. Token and principal revocation delete durable rows before removing
matching ETS entries, also within one call. They acknowledge only after both
steps succeed. A failing backend callback crashes the singleton rather than
acknowledging revocation; losing that process also discards its ETS cache.
The backend must make successful deletions durable and visible across nodes.
Callbacks must not re-enter `Sessions`.

A cache miss obtains a fresh-read ticket from the singleton. The persistent
read still executes in the fetching process, allowing revocation to complete
while a read is paused. The resulting row can enter ETS only if its ticket
matches the singleton's current ticket. Every successful revocation replaces
that ticket. Every singleton incarnation starts with a new reference, so a
read spanning process restart or node migration cannot restore under the new
incarnation. There is no unconditional restore operation.

If restoration enters the singleton first, subsequent revocation removes it.
If revocation completes first, the pending restoration's ticket is stale and
it returns `{:error, :unknown_session}`. A later read cannot recover the token
because its durable row has been deleted. This orders the public operations;
it does not cancel a protected request that authenticated before revocation.

The ticket is deliberately global: even unrelated revocation refuses a pending
read once. It does not delete the unrelated durable session; a fresh fetch
recovers it. Already cached unrelated sessions remain usable. Native sessions
retain their original `authenticated_at` across restart and node migration.
Browser sessions retain their existing expiration and memory-only behavior.

All nodes must configure the same durable backend. These guarantees use the
existing connected-cluster singleton model. This change does not introduce
partition fencing or a consensus protocol for disconnected duplicate singletons.

## Deterministic regressions

`SessionRevocationRaceTest` uses a shared durable-store model whose read captures
a row and pauses outside its Agent. A message barrier, not a sleep, establishes
the overlap. Token or principal revocation completes from another BEAM node;
only then does the test release the old read. It checks refusal locally and
from the peer, after restart, and after actually moving the singleton to the
peer. A separate, unrevoked credential survives that move with its original
sign-in time. Additional cases hold a read across revocation plus restart and
across restart alone; the latter proves fresh retrieval of the unrevoked row.

`NativeSessionRevocationTest` uses the production Postgres store through a
read-pause wrapper. It covers token and principal deletion, invalidation of the
captured read, absence of the durable row, refusal after restart, and survival
of another principal's credential. These tests use the normal shared SQL
sandbox; the peer/migration cases use the store model, not PostgreSQL.

## Actual local validation

Toolchain: Elixir 1.19.0, Erlang/OTP 27.3.4, PostgreSQL 16 with PostGIS.

- Negative control: replace only `sessions.ex` with baseline `c4fb5f1` and run
  the initial three `session_revocation_race_test.exs` cases: **3 tests,
  3 failures**. Each returns `{:ok, session}` from the paused fetch after the
  durable credential was revoked. Restore the correction before positive tests.
- `apps/biz_kit_identity`: `MIX_ENV=test mix test`: **40 tests, 0 failures**.
- `apps/spruce_goose`: `mix test test/native_session_revocation_test.exs`:
  **2 tests, 0 failures**, against a newly created and migrated PostgreSQL DB.
- `apps/dispatch`: `mix test --include integration`: **331 tests and
  2 doctests, 0 failures**, against a migrated PostGIS DB.
- SpruceGoose PostgreSQL-backed native sign-in, web auth, local identity, and
  the new revocation file together: **22 tests, 0 failures**.
- Cluster primitives: **3 tests, 0 failures**.
- Identity compilation with `--warnings-as-errors`: passed.
- Changed Elixir files: formatting check; `git diff --check`: passed.

Identity's pre-existing kill/restart cases emit logger formatter-crash messages
on this local OTP build; ExUnit reports no failures. These are not evidence of
successful hosted CI or deployed WorkOS/Android acceptance. The Consolidation
workflow already runs the full Identity and SpruceGoose suites; its explicit
format list now includes the new regression files.

The portal session P1, transactional administrative-authority P1, and required
hosted Dispatch integration P2 remain open. Passing Dispatch integration tests
locally does not make them a required hosted check. No production cutover
readiness is claimed.
