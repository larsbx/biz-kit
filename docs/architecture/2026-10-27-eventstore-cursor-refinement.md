# EventStore consumer cursor — proof-to-PostgreSQL refinement (staging only)

Date: 2026-10-27. **Not deployed. Not a second business ledger.**

This slice follows [merged PR #162](https://github.com/larsbx/biz-kit/pull/162):
`formal/lean/BizKitBundles.lean`,
`formal/quint/cursor_transaction.qnt`, and the cursor-first, partial-bundle
and double-launch negative controls.

**The formal workflows were queued at the first implementation checkpoint.**
Merging the proof source does not establish successful Lean kernel checking,
Quint verification, or that this PostgreSQL implementation refines the model.
Review the exact-head proofs and these database tests before any merge/cutover.

## Model-to-code correspondence

| Formal transition/property | Proposed SQL/Elixir implementation | Acceptance |
| --- | --- | --- |
| Event append advances only `head` | `CoopSubstrate.Log` remains sole signed business writer | No new appender or second event stream |
| `requiredEffects(event)` | `AgentOpsStore.EventEffects.derive/2` is a pure, fail-closed mapping | Unreviewed type cannot advance |
| Register all required effects | `agent_ops.consumer_effects` | Whole bundle inserted, no duplicate IDs |
| Explicit processed receipt, including no-op | `agent_ops.consumer_processed` | Empty bundle still inserts receipt |
| Cursor advances exactly once | `agent_ops.consumer_cursors` | `last_seq` advances by precisely one |
| Atomic `commitNext` / `atomicBundleCommit` | `agent_ops.commit_event_bundle` locks cursor, inserts bundle/receipt, advances in ONE PostgreSQL transaction | Constraint violation must rollback effects, receipt and cursor |
| Duplicate event delivery is harmless | Immutable event-ID/digest/bundle comparison | Exact replay returns `existing`; conflicting replay refused |
| Crash or lost notification preserves durable state | PostgreSQL WAL transaction semantics (host/platform) | Restart/partition acceptance still required |
| Single effect winner and cancel fencing | Existing `agent_ops.claim_attempt` CAS + current signed grants | No agent launch from consumer insert |

**Crucial distinction:** A committed `consumer_effects` row is a
*non-executable operational candidate*, not a task assignment, permission,
event authenticity proof, artifact custody receipt, business effect, or
successful external provider call.

## Boundaries and input trust

`EventCursor.commit/2` receives a trusted event descriptor whose `home_id`
is configured locally, whose `global_seq`, `event_id` and SHA-256
`event_digest` must have been obtained from the canonical accepted
`CoopSubstrate.Log` replay. It **does not independently verify signatures**
or check the EventStore head. The caller must use
`CoopSubstrate.Log.read_all(from:..., as_of:...)` and the canonical full
event hash; it MUST NOT take sequence or digest from a `:pg` notification,
an agent result, ActivityPub, or arbitrary web request.

The `consumer_id` identifies a **reviewed operational consumer**. There is
one authoritative EventStore per independently administered home; there is
no global federation cursor and no multi-home transaction coordinator.

The pure `EventEffects` mapper handles signed agent-run request,
cancellation, task-access revocation and offboarding events as **candidate
effect metadata**. Events irrelevant to this consumer require an explicitly
reviewed `ignored_types` list, giving them a durable processed-no-op
receipt. Unreviewed/new types fail closed and halt cursor progress rather
than disappearing. The host must not provide that list from user input.

No worker is activated by these records. The separate staging coordinator
must verify *fresh* signed task, principal, tenant/project, independent read
and execute grants, current profile, consent and runtime custody **after**
selection and before any privileged step.

## Database migration / roles

`deploy/agent-core/sql/004_event_cursor.sql` uses existing `agent_ops`
in the **same governed PostgreSQL database** as CoopSubstrate. Its tables
are separate from EventStore-owned tables. The trusted database role must
have narrowly granted `USAGE`, `SELECT` and `INSERT/UPDATE` on these
new operational tables and `EXECUTE` on `commit_event_bundle`. Defaults
for `PUBLIC` are revoked. The function is `SECURITY INVOKER`; no sandbox,
browser, plugin, or remote agent may have direct access.

For local disposable Compose testing, apply in order:

```sh
for file in 001_agent_attempts.sql 002_attempt_cas.sql 003_recovery_custody.sql 004_event_cursor.sql; do
  docker compose -f deploy/agent-core/compose.yaml exec -T db \
    psql -U bizkit -d bizkit_agent_dev -v ON_ERROR_STOP=1 \
    < "deploy/agent-core/sql/$file"
done
```

Substitute `podman compose` where available. Named database volumes
persist PostgreSQL state; they are not the event bus.

The SQL acceptance file `ci_event_cursor.sql` checks multiple effects,
empty effects, immutable replay, global-sequence gap refusal, and home
isolation. The integration module
`apps/agent_ops_store/test/event_cursor_test.exs` additionally checks
rollbacks triggered by a unique effect conflict and two independent
PostgreSQL connections racing for the same next sequence. These tests are
CI requirements but not yet proof of full crash/restart behavior.

## Remaining before production

1. Obtain GREEN exact-head Lean/Quint checks, or repair broken proof claims.
2. Validate this SQL/Elixir refinement with real PostgreSQL tests on its
   exact PR head (not only syntax review).
3. Implement a narrowly authorized host that obtains events **only** by
   signed EventStore read, with a reviewed exhaustive event-type/no-op
   registry for its consumer.
4. Prove bounded catch-up, interrupted read, crash after external launch,
   restart and stolen worker lease against actual external backend effect-ID
   lookup (not just database functions).
5. Wire ephemeral `:pg` notifications as *wakeups* while retaining periodic
   durable replay and current-grant revalidation.
6. Complete historic writer fencing, production identity/permission gates
   and domain-specific signed event adoption under [#161](https://github.com/larsbx/biz-kit/issues/161).

**Do not merge this feature on unvalidated formal or SQL checks and do not
switch production authority because a candidate outbox exists.**
