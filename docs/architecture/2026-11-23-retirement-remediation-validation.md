# Retirement remediation validation

Date: 2026-11-23. Base: archive PR [#443](https://github.com/larsbx/biz-kit/pull/443)
at `1f3a9ac7f1480ecb5575fe4748920b0cb477aa4a`, stacked on fence PR #441
at `235f9b27e25e77ceb4902ea071925219a71405ff`.
The follow-up described here extends published remediation
[`5a12ed9e`](https://github.com/larsbx/biz-kit/commit/5a12ed9e36be7fb1cfb7db5df82b66f553c8b15d)
on `codex/sprucegoose-retirement-remediation`.

This records code and documentation remediation, not a production cutover.
The earlier standalone Postgrex-startup and duplicate-destination-name fixes
remain intact and are not new findings.

## Implemented boundary

- Strict native preflight reopens the selected archive and checks the exact
  raw manifest digest, schema/writer, seven present required tables, unique
  file coverage, safe regular files, sizes/hashes, COPY framing and counts,
  all 13 legacy outbox column names, the 11 required non-null outbox values,
  status/timestamp consistency and the adopted Systemwide SOP bytes. Extra
  preserved outbox columns are allowed; the two nullable legacy fields and
  added nullable columns remain supported, including reordered columns.
- The wrapper verifies a bounded canonical ledger prefix, including signatures
  and both chains, and checks historical governance-key authority. It selects
  an exact archive event/chapter/writer/digest before the earliest fence order.
  It does not re-adjudicate every unrelated domain admission rule.
- New fence admission requires an earlier archive assertion in the same
  chapter/writer scope, including earlier events in one atomic batch. Existing
  signed schemas and ordinary historical replay are unchanged.
- The fence CLI checks before key loading and again after confirmation. The
  installer checks again before opening the legacy database, requires the
  selected canonical order's chapter, writer, event ID and sequence and actual
  target hostname/database labels to match. Derived order records must have
  the requested type/chapter/known writer. An inconsistent stored database
  fence chapter/event is refused transactionally.
- The separate preflight command starts only an EventStore read client with
  read-only PostgreSQL sessions. It never starts the application/appender or
  repairs derived indexes. Receipts always state `cutover_authorized: false`.

Generic archive export and `--verify` retain their existing absent-table and
hash-check semantics; neither replaces strict cutover preflight. Directly
constructing a governance declaration remains an assertion: deterministic
ledger admission checks record ordering, not local archive bytes. Installation
cannot bypass file verification through the old three-argument API.

## Executed local acceptance

**The full umbrella build passed with `--warnings-as-errors`; the committed
acceptance runner passed 64 tests, 0 failures** at
`8b14a9b03c20ebb21063f9224cabf574527c41fa`. The independent Python
Consolidation workflow regression passed 11 tests, 0 failures after the
November 24 addition of the signed-retirement CI step.

| Test group | Count | Evidence exercised |
| --- | ---: | --- |
| Native archive preflight | 32 | Missing/corrupt files, wrong manifest digest, omitted/absent tables, duplicate JSON/paths, malformed COPY, complete outbox columns/non-null values/counts, SOP correspondence |
| Governance projection | 14 | Exact record/digest/scope; historical key declarations, rotation and revocation; first-fence ordering; duplicate identities/positions |
| API/CLI early boundaries | 7 | Required archive selection, byte/source refusal before ledger startup, no-history compatibility and CLI argument refusals |
| Writer-fence pure gate | 5 | Ordered archive prerequisite, scoped refusal, historical fold compatibility, derived order scope and full canonical preflight/order identity |
| Real PostgreSQL archive/restore | 1 | All seven tables exported and restored, every row/field compared, including ETF/bytea, JSONB, timestamps/nulls and complete dispatched/pending/failed outbox records |
| Standalone ledger reader and verified replay | 5 | Read-only sessions, PostgreSQL refusing a write, no appender or index repair; real signed-vector replay, signature/chain/sequence/derived-stream corruption, wrong pinned head and short prefix refusals |

Toolchain: Elixir 1.19.0, OTP 27.3.4.1, PostgreSQL 17.12, Rust 1.100.0 and
CMake 3.31.6. All 91 Hex packages were downloaded at the exact `mix.lock`
versions and checked against both locked archive digests. Neither `mix.lock`
nor the canonical NIF's `Cargo.lock` changed. This includes Jason 1.4.5,
Postgrex 0.22.4 and EventStore 1.4.10. The native canonical encoder was built
and used by the replay tests; no production module was replaced by a mock.

This supersedes the initial 57-test result, which compiled a 70-module subset
because registry fetching was unavailable. The follow-up compiled the actual
umbrella and ran the committed entry point directly, after fetching the locked
dependency archives. The source diff was unchanged throughout that acceptance
run. These are local execution results. Hosted results for
[PR #445](https://github.com/larsbx/biz-kit/pull/445) must be read separately
at their reported source and checkout revisions.

The four added replay cases reuse the existing canonical bytes and signature
of the committed `envelope-core` vector. They create no signature or governance
record. A disposable fixture loader stores that non-governance event directly
in a fresh EventStore, then the real read-only client and `Log.replay_verified/2`
verify it. A valid signature cannot substitute for the missing archive record.
The frozen vector remains unchanged.

| Reproduction input | SHA-256 |
| --- | --- |
| `mix.lock` | `0680177a53eff1324bfe7d07a7408499d295f016e03ec6411fcc6b3bc893d78e` |
| `apps/coop_substrate/native/canonical_v1/Cargo.lock` | `ac2f7336ce70e0373e86dbbea5838a7fbd496ca658f12062306ef797db75efbe` |
| `apps/coop_substrate/test/vectors/canonical_v1_vectors.json` | `8049ceab69797aa48b4ab621c69aee3ab1f8a5bb9bd91bb05467ce5efe5f4d7d` |

With the repository's dependencies available, reproduce compilation and the
pure checks with:

```sh
MIX_ENV=test mix compile --warnings-as-errors
MIX_ENV=test mix run --no-start scripts/retirement_preflight_acceptance.exs
```

For restore and canonical-reader checks, supply an explicitly disposable loopback server
on a nondefault port and add `--restore`:

```sh
RETIREMENT_TEST_DATABASE_URL=postgres://test_user@127.0.0.1:PORT/postgres \
  MIX_ENV=test mix run --no-start scripts/retirement_preflight_acceptance.exs --restore
```

The runner avoids the normal test helper and the `mix test` alias that drops
the configured event store. Local acceptance created its own scratch
PostgreSQL cluster, shut it down and removed its data afterward. It did not
sign a governance record or install a writer fence.

All 19 Elixir files changed since the PR #443 base passed the repository's
`mix format --check-formatted`. `git diff --check` and changed-document local-link
checks passed. The two changed signed integration test modules were compiled
against the full umbrella as definitions with ExUnit autorun disabled and
statically reviewed. They were not executed.

## Continuous acceptance

Consolidation now includes the same boot-free `--restore` runner against its
disposable PostgreSQL service on explicit loopback port 55473. The separately
authorized signed-retirement step runs the 17 history-archive/writer-fence
integration tests against that job's disposable service on port 5432. Both
guards require successful umbrella compilation, permit execution after an
unrelated suite failure, and stop on cancellation. The 11-test Python workflow
regression checks these dependencies and keeps each step's failure red without
blocking the other retirement check.

## Authorized signed integration (2026-11-24)

The owner approved governance signing and fence installation solely in
disposable test environments, plus opening the stacked review PR. PR #445 is
based on #443's branch, `ccr-867804bc-bqx5an-history`. Its focused CI command is:

```sh
# Within apps/coop_substrate, using the CI job's disposable PostgreSQL service:
MIX_ENV=test mix test test/history_archive_test.exs test/writer_fence_test.exs --trace --seed 1
```

Retain the step-level result of `Test signed retirement archive and fence boundaries` separately
from `Test retirement preflight without application boot`; the latter does
not generate signatures or install fences. Consolidation's default checkout
tests GitHub's synthetic PR merge commit. Record the PR head and actual checkout
SHA/tree with hosted evidence; do not describe it as an exact-head checkout.

For local reproduction, do not assume `EVENTSTORE_PORT` redirects the signed
suite: test configuration uses port 5432 for both EventStore and Records, and
the `mix test` alias resets its configured database. Use a wholly disposable
5432 service, or explicitly configure both stores before any startup/reset.
This authorization does not extend to production archives, governance records,
writer fences, deployment configuration or merging the PR.

## Roadmap correction

The roadmap and existing cutover runbook now distinguish legacy
`ledger replay-status` from source-to-TaskCore parity. The former compares
legacy certified projections with legacy rows; acceptance still needs a
read-only report tied to the source snapshot/position and target canonical head,
reviewed identity mappings and every retained-field discrepancy disposition.
Target project and ownerless-project reads must be reconciled with the entire
live legacy inventory; an empty target ownerless list cannot prove migration
completeness. The backfill CLI is a governance write, not an inventory command.

## Remaining gates

The normal isolated signed integration suite must still exercise admission of
real governance/archive/fence records, atomic `[archive, fence]` acceptance /
`[fence, archive]` refusal, trigger installation, conflicting installed identities,
exemptions, retries and concurrency. Replaying a committed signed non-governance
vector exercises cryptographic prefix verification, but does not execute those
authority-changing paths. The November 24 test-only authorization and PR #445
enable their hosted execution; inspect the actual signed step's result before
closing this engineering gate. No operational gate follows from a synthetic
test signature or fence.

Production closure remains the [cutover acceptance runbook](2026-11-23-retirement-cutover-acceptance.md):
owner backfill, explained parity, physical source identity, source/provenance
quiescence, final durable verified copies, outbox dispositions, the authorized
fence, post-fence replay/restart and fresh-event-preserving recovery, plus
independent Mama succession. The signed fence still contains only `writer`
and `reason`; keep the selected archive reference in the operational receipt.

The roadmap reconciliation preserves the later owner decisions. Eatsbot's
confirmed disposable stack requires no archival/drain exercise; its host,
external infrastructure, credentials and repository archival are separate
remaining actions. No production archive, production governance signing,
production writer-fence installation or deployment-configuration change is
recorded by this work.
