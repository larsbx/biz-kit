# Task timing and agent suggestions on the common ledger

Date: 2026-10-18. Status: **draft schema, not implemented.** Scope: the ledger
events behind a calendar client in which people edit task timing directly
and agents only suggest changes for a person to accept.

Builds on the [first task command](2026-10-11-first-ledger-task-command.md),
[readiness](2026-10-14-ledger-task-readiness.md) and
[DoD review](2026-10-11-dod-evidence-review.md) stages. Every convention
there carries over unchanged: additive `V1` types merged into
`CoopSubstrate.Tasks.event_types/0`, exactly one signer per task event,
`<chapter>/<prefix>/<tenant>/<project>[/<task>]` streams, bounded scope
segments, `*_ms` integer UTC times, optimistic version preconditions,
same-envelope retry, and admission solely through `Log.append/2`.

## Permission model

Authority comes from grants, not from the client. Two roles act here:

| Role | Grant | May append | Effect on task state |
| --- | --- | --- | --- |
| operator (a person; key held in the client's OS keychain) | existing `TaskOperatorGrantedV1` | `TaskCreatedV1`, `TaskTimingRevisedV1`, `TaskSuggestionDeclinedV1` | yes |
| suggester (an agent) | new `TaskSuggesterGrantedV1` | `TaskChangeSuggestedV1`, `TaskSuggestionWithdrawnV1` | **none** |

The proposal/commit split is enforced by the gate, not by convention. A
suggester grant can never sign an operator command (the role and key differ),
and suggestion events are absent from the task fold:

    fold_tasks(L) = fold_tasks(L ∖ S)   where S = {e ∈ L | e.type ∈ Suggestion*}

An agent's whole effect is therefore an entry in the review queue. A
suggestion takes effect only when an operator signs the corresponding command,
which carries the suggestion ID as provenance.

Suggestions are ledger events rather than rows in a side table. That way the
review queue (the calendar's ghost events) is a replayable projection, it
reaches clients through the same change stream as accepted edits, and each
accept or decline is itself an attributable fact.

## Timing is a separate facet

The calendar edits timing far more often than the lifecycle changes. If
timing edits advanced the task's `version`, every drag would invalidate
in-flight `TaskQueuedV1`/`TaskReadyV1` commands. So timing gets its own counter:

- `task.version` is advanced only by lifecycle and DoD commands, as today.
- `task.timing_version` (starting at 0) is advanced only by `TaskTimingRevisedV1`.

Timing commands check `expected_timing_version`; lifecycle commands still
check `expected_version`. The two facets never conflict with each other.

### `timing` value

A full replacement, never a patch: a retry or replay is idempotent, and a
diff is computed by the reader.

```json
{
  "schedule": null | {
    "kind": "timed",
    "start_ms": 1792396800000,
    "end_ms": 1792400400000,
    "tz": "Europe/Copenhagen"
  } | {
    "kind": "all_day",
    "start_date": "2026-10-19",
    "end_date": "2026-10-21"
  },
  "due_ms": null | 1792483200000
}
```

Admission constraints (checked at append; violations are rejected, never
normalised):

- `timing` has exactly the keys `schedule` and `due_ms`; each `schedule`
  variant has exactly the keys shown.
- `timed`: `0 ≤ start_ms < end_ms`, and `end_ms − start_ms ≤ 31 days`.
  `tz` is an IANA zone name matching `^[A-Za-z_]+(/[A-Za-z0-9_+-]+){0,2}$`.
  It records the zone the instant was chosen in, for display and later
  recurrence; the instants are authoritative. The gate checks only the
  shape, because the runtime has no timezone database.
- `all_day`: ISO dates with `start_date < end_date` (end exclusive, as in
  iCalendar), spanning at most 366 days. These are floating dates with no zone.
- `due_ms`: `null` or an integer `≥ 0`, independent of `schedule`.

Recurrence is out of scope. When it is added, it gets its own versioned
`schedule.kind`.

## Events

`@scope` (`tenant_id`, `project_id`) and `@subject` (`@scope` plus `task_id`) are
the existing maps in `CoopSubstrate.Tasks`. `@actor` (`principal_id`,
`authorization_event_id`, `lifecycle_version`) is the existing map in
`Tasks.Readiness`. `spec/5` is `spec/4` with an `optional` payload map, to be
added in the implementation.

```elixir
@suggester %{"principal_id" => :string, "authorization_event_id" => :string}

%{
  # -- governance: suggester grants (mirrors TaskReviewerGrantedV1) ----------
  "TaskSuggesterGrantedV1" =>
    spec("governance", "task_suggesters", @scope, %{
      "principal_id" => :string,
      "key_id" => :string,
      "pubkey" => :pubkey
    }),
  "TaskSuggesterRevokedV1" =>
    spec("governance", "task_suggesters", @scope, %{
      "authorization_event_id" => :string
    }),

  # -- operator: authoritative task commands ---------------------------------
  "TaskCreatedV1" =>
    spec("operator", "tasks", @subject, Map.merge(@actor, %{
      "title" => :string,
      "timing" => :any
    }), %{"description" => :string, "suggestion_event_id" => :string}),
  "TaskTimingRevisedV1" =>
    spec("operator", "tasks", @subject, Map.merge(@actor, %{
      "expected_timing_version" => :int,
      "timing" => :any
    }), %{"suggestion_event_id" => :string}),
  "TaskSuggestionDeclinedV1" =>
    spec("operator", "task_suggestions", @scope, Map.merge(@actor, %{
      "suggestion_event_id" => :string,
      "reason" => :string
    }), %{}),

  # -- suggester: review-queue entries, no task effect -----------------------
  "TaskChangeSuggestedV1" =>
    spec("suggester", "task_suggestions", @scope, Map.merge(@suggester, %{
      "task_id" => :string,
      "change" => :any,
      "rationale" => :string
    }), %{"base_timing_version" => :int}),
  "TaskSuggestionWithdrawnV1" =>
    spec("suggester", "task_suggestions", @scope, Map.merge(@suggester, %{
      "suggestion_event_id" => :string
    }), %{})
}
```

Suggestions live on the project stream `<chapter>/task_suggestions/<tenant>/<project>`
rather than on the task's own stream. A task stream then contains only
authoritative facts, and a create suggestion has no task stream yet.

### `change` (Δ)

Each Δ is exactly the body of the command it would become, so accepting
means signing that body unchanged:

| `change.kind` | Fields | Accepted by | Requires |
| --- | --- | --- | --- |
| `create` | `title`, `timing`, optional `description` | `TaskCreatedV1` | `task_id` not yet recorded |
| `timing` | `timing` | `TaskTimingRevisedV1` | `base_timing_version` present; task exists |

`timing` uses the shape and constraints above, so an invalid Δ is
rejected at suggestion time rather than discovered when someone accepts it.

## Admission rules

Common to all: one signer; scope segments valid; the referenced grant is
active, its scope equals the event's chapter/tenant/project, and the signer's
`(key_id, pubkey)` and `principal_id` match the grant; the event ID has not
been recorded (the existing `duplicate/2` same-envelope retry applies).

| Event | Additional rule |
| --- | --- |
| `TaskSuggesterGrantedV1` / `RevokedV1` | declared governance key; same rules as reviewer grants |
| `TaskCreatedV1` | task key absent; `title` nonempty after trimming; `timing` valid. The task starts as `inbox`, `version = 1`, `timing_version = 1`, `dod: nil` |
| `TaskTimingRevisedV1` | task exists; `expected_timing_version = task.timing_version`; `timing` valid |
| `TaskChangeSuggestedV1` | `create`: task key absent. `timing`: task exists and `base_timing_version ≤ task.timing_version` |
| `TaskSuggestionWithdrawnV1` | suggestion pending, and signed by the principal who made it |
| `TaskSuggestionDeclinedV1` | suggestion pending, same scope; `reason` may be empty |
| any operator command carrying `suggestion_event_id` | suggestion pending, same scope and `task_id`, and its `change.kind` matches the command type |

Resolving a suggestion in the projection:

    status(s) ∈ {pending, accepted, amended, declined, withdrawn, superseded}

    accepted   ⇔ resolving command body = s.change body
    amended    ⇔ resolving command body ≠ s.change body (the operator edited before accepting)
    superseded ⇔ a `create` suggestion's task_id was created without citing it

A suggestion is resolved at most once; any later command that cites it is
rejected with `:suggestion_not_pending`. A `timing` suggestion whose
`base_timing_version < task.timing_version` is **stale**. That is a display
state, not an admission error: the person sees the Δ against the current
timing and decides. Accepting still checks the operator's own
`expected_timing_version` against current state, so a stale Δ can never be
applied blindly.

Revoking a grant stops new commands only. Accepted events, and pending
suggestions from a revoked suggester, remain; the queue shows the revocation.

## Projection additions

```elixir
task = %{..., timing: %{"schedule" => nil, "due_ms" => nil}, timing_version: 0}
state = %{..., suggester_grants: %{}, suggestions: %{}}
# suggestions: event_id => %{scope, task_id, change, base_timing_version,
#                            principal_id, status, resolved_by_event_id, global_seq}
```

Baselined tasks get `timing_version: 0` and empty timing. Importing legacy
`due_at` values needs a governance-signed baseline extension, so it is
out of scope here.

## Change stream (sketch)

An authenticated SSE endpoint emits one event per accepted envelope in the
reader's granted scopes, with `id: <global_seq>`. A reconnect resumes from
`Last-Event-ID`. Data is the event type, scope, `task_id`, event ID/hash and the
resulting projection fragment (task timing/versions or suggestion status).
Clients deduplicate by `global_seq` and apply in ledger order, matching the
Buzz notification contract. Human and agent changes travel through the same
stream, which is why suggestions are ledger events. The transport is
specified in a later document.

## Properties to test

1. **No agent effect:** replaying any ledger with all suggestion events removed
   yields the same task fold (StreamData over generated mixed batches).
2. **Facet independence:** timing commands never change `task.version`; lifecycle
   commands never change `timing_version`.
3. **Role separation:** a suggester key is rejected for every operator command,
   and an operator key for every suggester command, even when both grants
   name the same principal.
4. **Single resolution:** at most one command or decline resolves each suggestion,
   including within one atomic batch.
5. **Round trip:** for every valid Δ, the command built from the Δ body is
   admitted at the current timing version and resolves the suggestion as `accepted`.
6. **Validation totality:** every rejected `timing` maps to one named error;
   `timed` with `start_ms ≥ end_ms`, inverted all-day ranges and unknown keys
   are all rejected.
7. **Retry:** re-submitting the same signed envelope returns the original
   receipt, including after a revocation.

## Open decisions

- **May operators create tasks?** Today only governance records tasks, as
  baselines. `TaskCreatedV1` gives operators creation inside their granted
  project. The alternative is a governance-signed create, with operators
  limited to timing.
- **DoD for created tasks:** a created task has no DoD until
  `TaskDoDDefinedV1`, so the readiness rules keep it from becoming ready.
  Confirm this is intended rather than requiring a DoD at creation.
- **Rationale disclosure:** `rationale` is free text from an agent, stored in the
  ledger under the `:edges` class. Long reasoning should probably go to artifact
  custody, with only a digest in the event.
- **Who may suggest:** one suggester grant per agent principal and project, or
  per agent deployment. This document assumes per principal and project.
