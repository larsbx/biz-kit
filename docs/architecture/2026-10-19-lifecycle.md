# Lifecycle steps in the view

Date: 2026-10-19. Status: **implemented**. Follows
[deciding on suggestions](2026-10-18-decide.md) and
[editing before accepting](2026-10-19-amend.md).

## Decision

From the web view a person can now take each lifecycle step on a task,
signed on their device like a decision:

| Step | Command | From → to | Cites |
| --- | --- | --- | --- |
| Propose | `TaskProposedV1` | inbox → proposed | — |
| Acknowledge the SOP | `TaskSOPAcknowledgedV1` | proposed or queued | a custody receipt of the SOP |
| Queue | `TaskQueuedV1` | proposed → queued | — |
| Mark ready | `TaskReadyV1` | queued → ready | a custody receipt per required input |

A person can also **revoke a delegation they made**
(`TaskDelegationRevokedV1`), and the view lists **decided suggestions**
(accepted, amended, declined, withdrawn, superseded) with who suggested
them and any reason.

Withdrawals are an agent's own act, signed by the agent that suggested, so
the view shows them rather than performing them.

Artifacts are cited, not uploaded. The SOP and the inputs must already be
recorded in custody (`ArtifactCustodyRecordedV1`), by tooling or an agent.
The view picks a receipt in the project whose digest matches. Uploading
from the browser is not part of this change.

## Contract

`Tasks.Lifecycle` (pure) builds each step's command:
- **Task steps** expect the task's current version
  (`expected_version`), so a step prepared before someone else changed the
  task is refused as stale when it is submitted.
- **Revoking** names the delegation, which must be in the project.

`Commands.prepare/4` dispatches between decisions and lifecycle steps.
Whether a step is allowed is the ledger's to say, before anyone signs. The
ledger checks:
- the task's state;
- a Definition of Done, for queuing;
- a readiness definition, and the acknowledging principal's own
  acknowledgement made with the same key;
- receipts in the project whose digests match;
- predecessors completed, for ready.

A refusal now carries the ledger's own reason over HTTP, for example 409
`dod_not_defined` or `sop_acknowledgment_required`, rather than a generic
`refused_by_ledger`.

```
POST /api/v1/chapters/:c/tenants/:t/projects/:p/commands
  {"action": "propose" | "queue", "task_id", "key_id"}
  {"action": "acknowledge_sop", "task_id", "custody_receipt_id", "key_id"}
  {"action": "ready", "task_id", "custody_receipts": {name: receipt id}, "key_id"}
  {"action": "revoke_delegation", "delegation_event_id", "key_id"}
```

**Feed.** For the view to know what each step needs, the change feed now
carries:
- a task's `readiness`: requirements, predecessors and SOP digest, plus the
  acknowledging principal, its key ID and the receipt (not the public key);
- the project's custody receipts, as a new `:receipts` kind with `digest`
  and `principal_id`.

## The web view

Each task shows its next step for the signed-in person as a button, or what
it is waiting for. `view.js` `nextStep/3` works this out, and it is pure:

- `inbox`: **Propose**.
- `proposed`:
  - without a Definition of Done or readiness: waiting for that;
  - not yet acknowledged by this person on this device (the ledger checks
    the key, so an acknowledgement from another of their devices does not
    count): **Acknowledge the SOP**, citing a receipt with the SOP's
    digest, or waiting for a stored copy;
  - otherwise: **Queue**.
- `queued`:
  - waiting for unfinished predecessors, or for a stored copy of a required
    input;
  - otherwise: **Mark ready**, citing a receipt for each input.

Every step goes through the same decode, check and confirm as a decision.
The page signs only if the command names this task at the version shown,
with exactly the receipts it chose.

*Delegations you made* lists the person's active delegations, each with
**Revoke**. *Decided suggestions* shows the twenty most recently decided
suggestions, ordered by the event that resolved them.

## Verification

- **`LifecycleTest`** (ledger):
  - inbox to ready, every step signed on the device;
  - each step refused before signing when the ledger would refuse it:
    wrong state, no DoD, no readiness, no acknowledgement, the wrong
    receipt, missing receipts, an unknown task;
  - a step prepared before the task changed is refused as stale;
  - revoking a delegation.
- **`SpruceGoose.Web.LifecycleTest`:**
  - propose over HTTP;
  - `dod_not_defined` and `invalid_task_transition` named on refusal;
  - revoking a delegation;
  - `bad_action`, `unknown_task` and `unknown_delegation`.
- **Feed:** the generated histories now put receipts in the view.
- **Node:** `nextStep` for each state, including someone else's
  acknowledgement, unfinished predecessors and missing inputs;
  `decidedSuggestions` orders and filters.
- **Browser (Chromium):** after accepting and amending, the device:
  1. proposes the task it created;
  2. once governance defines its DoD and readiness and the inputs are in
     custody, acknowledges the SOP;
  3. queues the task;
  4. marks it ready.

  The ledger holds each step signed by the browser's key, and the task is
  `ready`.
- **Mutation:** if the server prepares `TaskReadyV1` without the receipts
  the page chose, the browser test fails.

## Not yet

- Uploading an SOP or input from the browser is now
  [offered](2026-10-19-uploads.md).
- Steps after ready (start, evidence, review, complete) are now
  [offered](2026-10-19-execution.md).
