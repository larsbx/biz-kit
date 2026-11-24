# Retirement remediation validation

Date: 2026-11-23. Base: archive PR [#443](https://github.com/larsbx/biz-kit/pull/443)
at `1f3a9ac7f1480ecb5575fe4748920b0cb477aa4a`, stacked on fence PR #441
at `235f9b27e25e77ceb4902ea071925219a71405ff`.

This records code and documentation remediation, not a production cutover.
The earlier standalone Postgrex-startup and duplicate-destination-name fixes
remain intact and are not new findings.

## Implemented boundary

- Strict native preflight reopens the selected archive and checks the exact
  raw manifest digest, schema/writer, seven present required tables, unique
  file coverage, safe regular files, sizes/hashes, COPY framing and counts,
  all 13 legacy outbox column names, outbox status/timestamp consistency and
  the adopted Systemwide SOP bytes. Extra preserved outbox columns are allowed.
- The wrapper verifies a bounded canonical ledger prefix, including signatures
  and both chains, and checks historical governance-key authority. It selects
  an exact archive event/chapter/writer/digest before the earliest fence order.
  It does not re-adjudicate every unrelated domain admission rule.
- New fence admission requires an earlier archive assertion in the same
  chapter/writer scope, including earlier events in one atomic batch. Existing
  signed schemas and ordinary historical replay are unchanged.
- The fence CLI checks before key loading and again after confirmation. The
  installer checks again before opening the legacy database, requires the
  selected canonical order and actual target hostname/database labels to
  match, and refuses an inconsistent stored fence chapter/event transactionally.
- The separate preflight command starts only an EventStore read client with
  read-only PostgreSQL sessions. It never starts the application/appender or
  repairs derived indexes. Receipts always state `cutover_authorized: false`.

Generic archive export and `--verify` retain their existing absent-table and
hash-check semantics; neither replaces strict cutover preflight. Directly
constructing a governance declaration remains an assertion: deterministic
ledger admission checks record ordering, not local archive bytes. Installation
cannot bypass file verification through the old three-argument API.

## Executed acceptance

**57 tests passed, 0 failures** after the full outbox-field safeguard.

| Test group | Count | Evidence exercised |
| --- | ---: | --- |
| Native archive preflight | 30 | Missing/corrupt files, wrong manifest digest, omitted/absent tables, duplicate JSON/paths, malformed COPY, complete outbox fields and counts, SOP correspondence |
| Governance projection | 14 | Exact record/digest/scope; historical key declarations, rotation and revocation; first-fence ordering; duplicate identities/positions |
| API/CLI early boundaries | 7 | Required archive selection, byte/source refusal before ledger startup, no-history compatibility and CLI argument refusals |
| Writer-fence pure gate | 4 | Ordered archive prerequisite, scoped refusal, historical fold compatibility and exact preflight/order identity |
| Real PostgreSQL archive/restore | 1 | All seven tables exported and restored, every row/field compared, including ETF/bytea, JSONB, timestamps/nulls and complete dispatched/pending/failed outbox records |
| Standalone ledger reader | 1 | Read-only session setting, PostgreSQL refusing a write, no substrate application/Log/Records startup, clean reader shutdown and unchanged empty ledger/index counts |

Toolchain: Elixir 1.19.0, OTP 27.3.4.1, PostgreSQL 17.12. Jason 1.4.5,
Postgrex 0.22.4, EventStore 1.4.10 and their exercised dependencies came from
tarballs checked against the repository's locked checksums.

The local environment could not fetch the full Hex registry, so the execution
compiled a focused set of 70 actual repository modules and invoked the same
committed acceptance entry point. No production modules were replaced by
mocks. The subset emitted 52 unresolved-remote warnings for excluded, uncalled
NIF/domain/signing paths. This is targeted validation, not a successful full
umbrella build or hosted CI result.

The normal reproduction command, with the repository's dependencies available,
is:

```sh
MIX_ENV=test mix run --no-start scripts/retirement_preflight_acceptance.exs
```

For the two database checks, supply an explicitly disposable loopback server
on a nondefault port and add `--restore`:

```sh
RETIREMENT_TEST_DATABASE_URL=postgres://test_user@127.0.0.1:PORT/postgres \
  MIX_ENV=test mix run --no-start scripts/retirement_preflight_acceptance.exs --restore
```

The runner avoids the normal test helper and the `mix test` alias that drops
the configured event store. Local acceptance created its own scratch
PostgreSQL cluster, shut it down and removed its data afterward. It did not
sign a governance record or install a writer fence.

Changed Elixir files were formatted; `git diff --check` and changed-document
local-link checks passed. The two changed signed integration test modules were
compiled as definitions with ExUnit autorun disabled and statically reviewed.
They were not executed.

## Remaining gates

The normal isolated signed integration suite must still exercise atomic
`[archive, fence]` acceptance / `[fence, archive]` refusal, canonical verification
of real signed records, trigger installation, conflicting installed identities,
exemptions, retries and concurrency. The standalone reader check used an empty
canonical ledger and does not substitute for the signed-prefix integration.

Production closure remains the [cutover acceptance runbook](2026-11-23-retirement-cutover-acceptance.md):
owner backfill, explained parity, physical source identity, source/provenance
quiescence, final durable verified copies, outbox dispositions, the authorized
fence, post-fence replay/restart and fresh-event-preserving recovery, plus
independent Mama succession. The signed fence still contains only `writer`
and `reason`; keep the selected archive reference in the operational receipt.

The roadmap reconciliation preserves the later owner decisions. Eatsbot's
confirmed disposable stack requires no archival/drain exercise; its host,
external infrastructure, credentials and repository archival are separate
remaining actions. No production archive, governance signing, writer-fence
installation or deployment-configuration change is recorded by this work.
