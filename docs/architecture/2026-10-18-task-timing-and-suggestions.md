# Task timing and agent suggestions on the common ledger

Date: 2026-10-18. Status: **ledger events implemented** in
`CoopSubstrate.Tasks.Timing`, specified in
[`spec/task_suggestions.qnt`](../../apps/coop_substrate/spec/task_suggestions.qnt). The change
stream, HTTP/MCP wrappers and calendar client are not built yet. Scope: the ledger
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
| suggester (an agent) | new `TaskSuggesterGrantedV1` | `TaskChangeSuggestedV1`, `TaskSuggestionWithdrawnV1`, `TaskSuggestionArtifactRecordedV1` | **none** |

The proposal/commit split is enforced by the gate, not by convention. A
suggester grant can never sign an operator command (the role and key differ),
and suggestion events are absent from the task fold:

    fold_tasks(L) = fold_tasks(L ∖ S)   where S = {e ∈ L | e.type ∈ Suggestion*}

An agent's whole effect is therefore an entry in the review queue.

### Reasoning is preserved, including reasons not to act

Each suggestion carries a short `rationale` and may cite a fuller document
the agent stored itself. Declines and withdrawals can carry reasons in the
same way. The reasoning behind a suggestion that was declined, or behind one
an agent withdrew, is kept as evidence of what was considered and why it
wasn't done. It does not disappear when the suggestion is closed.

Agents record these documents with `TaskSuggestionArtifactRecordedV1`. It
uses the same out-of-log byte store and the same admission check (the gate
re-reads the stored bytes and recomputes their SHA-256) as
`ArtifactCustodyRecordedV1`, but it is a **separate type, with receipts folded
into a separate map** (`suggestion_artifacts`, not `custody_receipts`).

That separation is what preserves the rule above. DoD evidence
(`TaskEvidenceSubmittedV2`), SOP acknowledgement (`TaskSOPAcknowledgedV1`) and
ready inputs (`TaskReadyV1`) all resolve receipts from `custody_receipts`. If
agent receipts were folded there, an operator command could cite one, and
removing the agent's event would then change the task fold. An operator who
wants an agent's document as task evidence records their own
`ArtifactCustodyRecordedV1` for the same digest. The bytes are already in the
store, and the operator's receipt re-verifies them under operator authority.

### Task creation

The ledger has no creation command today. `TaskBaselineRecordedV1` is an
import: it requires a `legacy_row_id`, a `source_digest` and a `definition_ref`,
and attests a preserved SpruceGoose row. `TaskCreatedV1` is the first event
that creates new work, and it is **operator-signed** (decided 2026-10-18).

Authority splits by key:

| Key | Decides |
| --- | --- |
| operator (per person and project; revocable) | what exists in the inbox, and when it is scheduled |
| governance (per chapter; can issue grants) | what counts as done (`TaskDoDDefinedV1`), readiness rules, grants |

Creating a task confers no authority over its completion. A created task
starts with `dod: nil`, can reach `proposed` (which has no prerequisites),
and cannot reach `queued` until governance has signed both its Definition of
Done (`TaskDoDDefinedV1`) and its readiness definition (`TaskReadinessDefinedV1`).
The DoD requirement was added on 2026-10-18; see
[the readiness design](2026-10-14-ledger-task-readiness.md#definition-of-done-before-queuing).
The worst a misused operator key can do is add inbox tasks inside its own
project, and governance can revoke it. Routine creation therefore never
needs the governance key, which can stay offline.

Narrower operator roles (for example timing without creation) would need a
`TaskOperatorGrantedV2` that carries a capability list. That is deferred
until a second person needs one. A
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
- `task.timing_version` is 0 for a baselined task, which has no timing.
  `TaskCreatedV1` sets the initial timing and the counter to 1: creation counts
  as the first timing revision. After that, only `TaskTimingRevisedV1`
  advances it.

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
    }), %{"reason_receipt_id" => :string}),

  # -- suggester: review-queue entries, no task effect -----------------------
  "TaskChangeSuggestedV1" =>
    spec("suggester", "task_suggestions", @scope, Map.merge(@suggester, %{
      "task_id" => :string,
      "change" => :any,
      "rationale" => :string
    }), %{"base_timing_version" => :int, "rationale_receipt_id" => :string}),
  "TaskSuggestionWithdrawnV1" =>
    spec("suggester", "task_suggestions", @scope, Map.merge(@suggester, %{
      "suggestion_event_id" => :string
    }), %{"reason" => :string, "reason_receipt_id" => :string}),
  "TaskSuggestionArtifactRecordedV1" =>
    spec("suggester", "task_suggestions", @scope, Map.merge(@suggester, %{
      "artifact_digest" => :hash
    }), %{})
}
```

Suggestions live on the project stream `<chapter>/task_suggestions/<tenant>/<project>`
rather than on the task's own stream. A task stream then contains only
authoritative facts, and a create suggestion has no task stream yet.

### `change` (Δ)

Each Δ carries exactly the body fields of the command it would become, so accepting
means signing that body unchanged:

| `change.kind` | Fields | Accepted by | Requires |
| --- | --- | --- | --- |
| `create` | `title`, `timing`, optional `description` (a string; omitted, never `null`) | `TaskCreatedV1` | `task_id` not yet recorded |
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
| `TaskChangeSuggestedV1` | `create`: task key absent. `timing`: task exists and `base_timing_version ≤ task.timing_version`. `rationale` nonempty and at most 1,000 characters |
| `TaskSuggestionArtifactRecordedV1` | the gate fetches the bytes for `artifact_digest` from the store and recomputes the hash, as for operator custody; at most 1 MiB; event ID not already a receipt |
| `TaskSuggestionWithdrawnV1` | suggestion pending, and signed by the principal who made it |
| `TaskSuggestionDeclinedV1` | suggestion pending, same scope; `reason` may be empty |
| `rationale_receipt_id` / suggester `reason_receipt_id` | names a `suggestion_artifacts` receipt in the same chapter/tenant/project recorded by the **same principal**. An agent can cite only documents it stored itself |
| operator `reason_receipt_id` | names an operator `custody_receipts` entry in the same scope. An operator may not cite an agent's document as their own reason |
| any operator command carrying `suggestion_event_id` | suggestion pending, same scope and `task_id`, and its `change.kind` matches the command type |

Resolving a suggestion in the projection:

    status(s) ∈ {pending, accepted, amended, declined, withdrawn, superseded}

    body(create) = {title, timing, description}   body(timing) = {timing}

    accepted   ⇔ body fields of the resolving command = body fields of s.change
    amended    ⇔ they differ (the operator edited before accepting)
    superseded ⇔ a `create` suggestion's task_id was created without citing it

Every non-pending status has exactly one resolving event, recorded as
`resolved_by_event_id`. For `superseded` it is the `TaskCreatedV1` that created
the task without citing the suggestion. (The Quint model found this gap: a
superseded suggestion otherwise had no resolving event.)

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
state = %{..., suggester_grants: %{}, suggestions: %{}, suggestion_artifacts: %{}}
# suggestion_artifacts: event_id => %{chapter_id, tenant_id, project_id,
#                                     principal_id, digest}
# suggestions: event_id => %{chapter_id, tenant_id, project_id, task_id, kind,
#                            change, principal_id, base_timing_version, rationale,
#                            rationale_receipt_id, status, reason, reason_receipt_id,
#                            resolved_by_event_id}
# timing_commands: event_id => envelope, for same-envelope retry
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

## Verification

The admission rules are a state machine in
[`spec/task_suggestions.qnt`](../../apps/coop_substrate/spec/task_suggestions.qnt).
Its `safety` invariant combines the properties below.

```sh
apps/coop_substrate/spec/check.sh             # what CI runs (~3 min)
SAMPLES=20000 DEPTH=6 apps/coop_substrate/spec/check.sh
```

`check.sh` type-checks the spec, samples `safety`, requires every witness to be
violated, and runs the exhaustive bounded check. CI runs it as the
`ledger-model` job of the Consolidation workflow.

Results (Quint 0.25.1 with Apalache): no violation in 20,000 sampled
executions of up to 25 steps, and none in an exhaustive bounded check of every
execution up to 6 steps. The spec also has six witness invariants
(`noAccepted`, `noAmended`, …) that must be **violated**, proving the
interesting states are reachable. All six are.

The model found one gap in this design: a superseded suggestion had no
resolving event. The resolution rule above now names the creating event.

In Elixir, `TaskSuggestionsPropertiesTest` checks the same invariants over
generated histories through the pure admission path, and
`TaskTimingSuggestionsTest` covers each rule through `Log.append/2`. Writing
those tests exposed an implementation hazard: task types were listed by hand in
both `Validity` and the gate projection. A type admitted but not folded leaves
every later check reading stale state, so both lists are now derived from
`Tasks.event_types/0`.

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
8. **Receipt isolation:** every `suggestion_artifacts` receipt ID is rejected
   with `:unknown_custody_receipt` wherever DoD evidence, SOP acknowledgement or
   ready inputs resolve a custody receipt. This is property 1 made concrete
   for artifacts.
9. **Reasons survive closure:** for each suggestion that ends `declined` or
   `withdrawn`, its rationale receipt and any reason receipt remain resolvable
   from replay. Whether the bytes are still available is a store-retention
   question, not a ledger property.

## Decisions (2026-10-18)

- **Operators create tasks.** See [Task creation](#task-creation).
- **No DoD at creation.** A created task has `dod: nil`. It needs a
  governance-signed DoD and readiness definition before it can be queued (see
  [Task creation](#task-creation)).
- **Suggester grants are per agent principal and project,** not per deployment.
- **Agent reasoning stays out of the ledger body.** The `rationale` field holds
  a short summary (at most 1,000 characters). Full reasoning goes in the
  artifact store and is cited by receipt.
- **Agents store their own reasoning, at suggestion time.** Suggester grants
  admit `TaskSuggestionArtifactRecordedV1`, scoped to the suggester's project,
  so reasoning is kept whether or not the suggestion is accepted. Waiting for
  an operator to store it on acceptance would lose the reasons behind
  everything declined or withdrawn.

## Retention note

A custody receipt attests that the bytes were verified at admission, not that
they are kept forever (see [artifact custody](2026-10-12-artifact-custody.md)).
Deployment retention and backup policy must cover suggestion artifacts
explicitly. Otherwise the reasons for declined suggestions, the case this
design exists for, are the first thing a cleanup would remove.
