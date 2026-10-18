# Delegated task changes

Date: 2026-10-18. Status: **implemented** in `CoopSubstrate.Tasks.Delegation`
and `CoopSubstrate.Tasks.Timing`. Extends
[task timing and agent suggestions](2026-10-18-task-timing-and-suggestions.md).
State machine: [`spec/task_suggestions.qnt`](../../apps/coop_substrate/spec/task_suggestions.qnt).

## Why

Suggestions require a person to accept every agent change. For routine
scheduling that turns agents into a source of review work. A delegation lets an
operator approve a **class** of changes once, in advance. Agents then act
inside it without asking. Anything outside it still goes through the
suggestion queue.

## Decisions (2026-10-18)

- **Operators delegate**, each from their own operator grant. A delegation
  cannot exceed the grant it comes from, and dies with it.
- **Default split:**

  | Delegatable | Always needs approval (suggestion queue) |
  | --- | --- |
  | place an unscheduled task into a slot inside the window | change or clear a due date |
  | move a timed block whose old and new slots both lie inside the window | anything involving a slot outside the window, or an all-day schedule |
  | create tasks, if `create` is delegated (no due date, slot inside the window) | removing a task's slot (unscheduling) |
  | | lifecycle: proposing, readiness, completion |
  | | anything after the delegation is revoked or its budget is spent |

## Invariant change

The timing design's rule "agents have no effect on task state" becomes:

> An agent changes task state only through a **live delegation**, and only
> within its limits. Every task change traces back to a human-signed grant.

Suggester-only agents are unaffected: suggestion events still never change
task state.

## Events

```elixir
"TaskDelegationGrantedV1" =>   # operator-signed; stream task_delegations/<tenant>/<project>
  spec("operator", "task_delegations", @scope,
    Map.merge(@actor, %{                  # the delegating operator and their grant
      "delegate_principal_id" => :string, # the agent
      "key_id" => :string, "pubkey" => :pubkey,
      "kinds" => :any,                    # nonempty subset of ["timing", "create"]
      "window" => :any,                   # %{"not_before_ms" => int, "not_after_ms" => int}
      "max_block_ms" => :int,             # 1 ms .. 31 days
      "budget" => :int                    # 1 .. 10,000 admitted changes
    }),
    %{"task_ids" => :any,                 # nonempty list; absent = every task in the project
      "states" => :any})                  # lifecycle states; absent = ["inbox", "proposed"]

"TaskDelegationRevokedV1" =>   # operator-signed by the delegator
  spec("operator", "task_delegations", @scope,
    Map.put(@actor, "delegation_event_id", :string))
```

An agent acting under a delegation signs the **same commands an operator
does** (under the `operator` role tag those types require), `TaskCreatedV1` and `TaskTimingRevisedV1`. Its `authorization_event_id`
is the delegation's event ID, its `principal_id` is the delegate principal, and
its signature uses the delegation's key. The commands' `operator` role tag
fixes only the signature-set shape; the grant decides authority. Both commands
gain two optional fields, accepted **only** on delegated commands:

- `rationale`: short text, nonempty, at most 1,000 characters;
- `rationale_receipt_id`: a `suggestion_artifacts` receipt recorded by the same
  principal. `TaskSuggestionArtifactRecordedV1` is now admitted under a
  delegation as well as under a suggester grant. The agent signs it with the
  delegation's key under the `suggester` role tag that type requires. Role tags
  only shape the signature set; the grant or delegation decides authority.

Lifecycle commands (`TaskProposedV1`, readiness, DoD) look up operator grants
only, so a delegation can never authorise them.

## Admission rules

`TaskDelegationGrantedV1`, besides the usual operator checks:

| Field | Rule (error `{:invalid_delegation, field}`) |
| --- | --- |
| `kinds` | nonempty, no duplicates, each `"timing"` or `"create"` |
| `window` | exactly `not_before_ms`, `not_after_ms`; integers with `0 ≤ not_before_ms < not_after_ms` |
| `max_block_ms` | `1 ≤ max_block_ms ≤ 31 days` |
| `budget` | `1 ≤ budget ≤ 10,000` |
| `task_ids` | when present: nonempty, no duplicates, valid scope segments |
| `states` | when present: nonempty, no duplicates, each `inbox`, `proposed`, `queued` or `ready` |

`TaskDelegationRevokedV1`: the delegation exists in the same scope
(`:unknown_delegation`), was issued by the signing principal
(`:delegation_not_own`), and is active (`:delegation_already_revoked`).

A **delegated command** passes, in order:

1. **Liveness:** the delegation is active (`:delegation_revoked`), its
   delegator's operator grant is active (`:delegator_grant_revoked`), and
   `used < budget` (`:delegation_budget_exhausted`).
2. **Identity:** same scope, `principal_id` is the delegate
   (`:task_principal_mismatch`), the signing key is the delegation's
   (`:delegate_key_mismatch`), `lifecycle_version` is 1.
3. **Kind and target:** the command's kind is delegated
   (`:delegation_kind_not_allowed`), the task is in `task_ids` when given
   (`:delegation_task_not_allowed`), and the command cites no suggestion
   (`:delegated_cannot_resolve`, so agents never approve agents). A delegated
   creation still supersedes pending create suggestions for that task, as any
   creation does: superseding records that the task now exists, not an
   approval.
4. **Limits**, checked after the timing value itself is validated, so they
   never run on a malformed value. A timed slot is *inside the window* when
   `not_before_ms ≤ start_ms` and `end_ms ≤ not_after_ms`.
   - `TaskTimingRevisedV1`: the task's state is allowed
     (`:delegation_state_not_allowed`); `due_ms` is unchanged
     (`:delegation_cannot_change_due`); the new schedule is a timed slot
     inside the window (`:delegation_outside_window`) no longer than
     `max_block_ms` (`:delegation_block_too_long`); the current schedule is
     `null` or a timed slot inside the window (`:delegation_outside_window`).
   - `TaskCreatedV1`: `due_ms` is `null` (`:delegation_cannot_change_due`);
     the schedule is `null` or a timed slot inside the window, no longer than
     `max_block_ms`.
5. **Reasoning:** `rationale` and `rationale_receipt_id` are valid when present.
   On operator commands they are refused (`:rationale_requires_delegation`).
6. The command's own rules: timing shape, task existence, expected timing
   version.

## Projection

```elixir
state.delegations: event_id => %{chapter_id, tenant_id, project_id,
  delegator_principal_id, operator_grant_id, principal_id, key_id, pubkey,
  kinds, task_ids, states, window, max_block_ms, budget, used, active}
task.timing_delegation_id   # the delegation behind the latest timing change; nil if an operator made it
```

Each admitted delegated command increments `used`. Rejected commands and
recorded reasoning artifacts do not spend the budget. The calendar marks tasks
whose `timing_delegation_id` is set. Undoing a delegated change is an ordinary
operator `TaskTimingRevisedV1`.

## Verification

The Quint model gains delegations, grant epochs and a `{slot, due}` timing.
Its four new witnesses (a delegated move, a delegated create, an exhausted
budget, a delegation used and then ended) are all reachable. `spec/check.sh`
passes: `safety` holds over 3,000 sampled runs and exhaustively to depth 5
(about 7 minutes in all).

Mutation tests: removing any one of the gate's checks for due dates, window,
kind, revocation, budget or grant epoch makes the model fail `safety`.
Removing the due-date, budget or kind check from the Elixir implementation
makes the property suite fail.

`TaskDelegationTest` covers each admission rule through `Log.append/2`.
`TaskSuggestionsPropertiesTest` generates histories mixing suggestions,
delegations and revocations, and recomputes the limits below independently of
the implementation.

## Properties

Added to the Quint model and the Elixir property tests:

1. **Traceability:** every task change was admitted under an active operator
   grant, or under a live delegation whose delegator's grant was active.
2. **Limits:** every delegated change respects its delegation's kinds,
   targets, window, block length and states, and never changes a due date.
3. **Budget:** no delegation admits more than `budget` changes.
4. **Lifecycle stays human:** lifecycle commands are only ever operator-signed.
5. **Suggesters still have no effect:** unchanged from the timing design.
