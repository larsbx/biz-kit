# Cancel and reopen

Date: 2026-10-19. Status: **implemented**. Follows
[execution](2026-10-19-execution.md), which left a task that will not be
done with no way out: once started, it could only be completed.

## Decision

| Step | Command | Signed by | From → to | Needs |
| --- | --- | --- | --- | --- |
| Cancel | `TaskCancelledV1` (new) | operator | inbox, proposed, queued or ready → cancelled | a reason |
| Cancel | `TaskCancelledByGovernanceV1` (new) | governance | any state short of completed → cancelled | a reason |
| Send back | `TaskReopenedV1` (new) | operator | in_progress → queued | a reason |

- **Before the work starts**, a person may call a task off from their own
  device.
- **Once it is under way**, only governance may cancel it: the work, and
  perhaps a reviewer's time, is already committed. Otherwise the task goes
  back to `queued` to be readied again.
- **Cancelled is final.** No command moves a cancelled task, and governance
  cannot cancel a completed one.
- **Reasons** are required (1–2048 characters, not blank;
  `invalid_reason`). They are recorded on the ledger and shown in the view.

## Rules (`Tasks.Readiness`, `Tasks.Timing`)

- **Send back** clears who started the task, the evidence and its review.
  The SOP acknowledgement and readiness definition stay, so marking it ready
  again rechecks the input receipts and predecessors, and starting it again
  rechecks the starter's acknowledgement.
- **Successors.** A cancelled task is not completed, so a successor that
  names it as a predecessor cannot become ready. Governance redefines the
  successor's readiness (without that predecessor) if the work should go
  ahead anyway; the ledger does not guess.
- **Suggestions.** Cancelling resolves the task's pending timing
  suggestions as `superseded`, with the cancellation as their resolving
  event (one resolving event per non-pending suggestion, as
  [before](2026-10-18-task-timing-and-suggestions.md)). Revising or
  suggesting timing for a cancelled task is refused (`task_cancelled`).
- **Projection.** A cancelled task carries `cancellation`: event ID, the
  cancelling principal (none for governance) and the reason. The change
  feed shows it.

## Governance: `mix coop.cancel`

```
mix coop.cancel <CHAPTER> <TENANT> <PROJECT> <TASK> --reason "Client withdrew" \
  --server https://bizkit.example
```

It shows the task's title and state and, once confirmed, signs exactly that
task's `TaskCancelledByGovernanceV1` with that reason
(`Cancellation.Canceller.cancels?/3`), using the governance key in
`HARNESS_KEYS_DIR`. Over HTTP, as for offboarding, the read and the request
to prepare are signed by the governance key (`Governance.Read`) and answer
only for the chapters it governs:

```
GET  /api/v1/chapters/:c/tenants/:t/projects/:p/tasks/:task_id   → {task_id, title, state, version}
POST …/tasks/:task_id/cancellation            {"governance_key_id", "reason"} → 201 the cancellation to sign
POST …/tasks/:task_id/cancellation/:held_id   {"signature"} → 201 {event_id, global_seq}
```

The signed-request check now lives in `SpruceGoose.Web.Requests`, shared by
offboarding and cancellation.

## The web view

A task before the work starts offers **Cancel…**; one in progress, **Send
back…**. Each asks for the reason and signs through the usual decode, check
and confirm. The page signs only the command for this task, at the version
shown, with the reason typed. A cancelled task shows who cancelled it
(or "governance") and why.

## Model

The Quint lifecycle is now a library, `spec/task_lifecycle.qnt`, checked by
two specs:

- **`task_readiness.qnt`**: the path to `completed`, without cancelling, so
  that random runs still reach a successor becoming ready;
- **`task_cancel.qnt`**: the same with `cancel` (by an operator or
  governance) and `reopen` in every step.

`safety` adds:

- **cancelled is final:** a task once cancelled is still cancelled;
- **cancelled only where allowed:** an operator only before the work
  starts, and nobody once completed.

The Definition of Done invariant now exempts a cancelled task, which needs
none: the model found that a task cancelled from the inbox would otherwise
violate it. Witnesses in `task_cancel.qnt` show an operator's cancellation,
governance cancelling work under way, a task sent back to queued, and a
successor left waiting on a cancelled predecessor. Mutants that let an
operator cancel work under way, or reopen a cancelled task, violate safety.
`check.sh` checks a spec without a step relation through its importers.

## Verification

- **`CancelReopenTest`** (ledger):
  - a person cancels with a reason; cancelled is final; a blank reason is
    refused;
  - each state before the work starts can be cancelled by a person, and a
    started task cannot;
  - governance cancels work under way, never a completed task;
  - the administrator's tool signs only that task and that reason;
  - a successor waits on a cancelled predecessor until governance redefines
    its readiness;
  - cancelling supersedes pending timing suggestions, and the task is not
    rescheduled;
  - a task sent back is queued with its work cleared, and is readied and
    started again.
- **`SpruceGoose.Web.CancelTest`:** cancel and reopen over HTTP with named
  refusals; `mix coop.cancel` against a running server; the task read
  refused unsigned or by a key that governs nothing.
- **Node:** which of cancel or send back a task offers, and how a
  cancellation is described.
- **Browser (Chromium):** the person cancels the rescheduled task from its
  card, with a reason, signed by the browser's key.
- **Mutation:** if the server prepares the cancellation with another
  reason, the page refuses to sign and the browser test fails.

## Limits

- Sending back always goes to `queued`; there is no way back to `proposed`
  (to change the Definition of Done, governance cancels and a new task is
  created).
- A cancelled task stays in the view, marked cancelled; there is no
  archive.
- The suggestions model (`spec/task_suggestions.qnt`) does not model
  cancellation; superseding on cancel is covered by `CancelReopenTest`.
