# Execution: start, evidence, review, complete

Date: 2026-10-19. Status: **implemented**. Follows
[lifecycle steps](2026-10-19-lifecycle.md) and
[uploads](2026-10-19-uploads.md). Closes the boundary the
[readiness design](2026-10-14-ledger-task-readiness.md#remaining-boundaries)
left open: nothing could complete a task, so a task with predecessors could
never become ready.

## Decision

After ready, a task is started, its work is evidenced against the
Definition of Done, a reviewer decides on that evidence, and an operator
completes it citing the review that accepted it.

| Step | Command | Signed by | From → to | Cites |
| --- | --- | --- | --- | --- |
| Start | `TaskStartedV1` (new) | operator | ready → in_progress | — |
| Submit evidence | `TaskEvidenceSubmittedV2` | operator | in_progress | a custody receipt per criterion |
| Review | `TaskDoDReviewedV1` | reviewer | in_progress | the current submission |
| Complete | `TaskCompletedV1` (new) | operator | in_progress → completed | the accepting review |

A review still never completes a task by itself
([DoD evidence and review](2026-10-11-dod-evidence-review.md)): it is the
reviewer's attestation, and the operator's signed completion is the
lifecycle act. Governance's key is not needed to complete work.

## Rules (`Tasks.Readiness`, `Tasks.DoD`)

- **Start** rechecks what ready admitted: the starter's own SOP
  acknowledgement, made with the signing key, and the input receipts, bytes
  included. The SOP may now also be acknowledged while a task is ready, so
  a person other than the one who readied it can start it.
- **Starting clears earlier evidence.** Evidence submitted while the task
  was still proposed is dropped, together with its review, so what completes
  the task is evidence of this work.
- **Evidence and review** are admitted while a task is proposed (as before)
  or in progress, never while queued or ready. A Definition of Done is still
  defined only while proposed. A new submission clears the review.
- **Review** is by an active reviewer grant's key, of the current
  submission, once, and never by the submitter's principal or key.
- **Complete** needs the task in progress and `review_event_id` naming the
  review on record, which must accept. Otherwise `dod_review_mismatch` or
  `dod_not_accepted`.
- A completed task is what a successor's readiness waits for
  (`incomplete_predecessors` until then).

## Reviewer devices

A reviewer device enrols as an operator device does
([device enrolment](2026-10-19-device-enrolment.md)), naming the role:

- the request and the statement the device signs carry `role`
  (`operator` or `reviewer`); the page checks it before signing;
- approval appends a `TaskReviewerGrantedV1`, which gains an optional
  `device_label` (1–80 characters);
- status is per role (`GET …/devices/:key_id?role=reviewer`); the same key
  may be enrolled in both roles;
- `mix coop.enrol` shows the role and signs exactly that grant;
- `mix coop.revoke` revokes a reviewer grant with `TaskReviewerRevokedV1`;
- reviewers read the project's feed (`Feed.Access`), signed or by session.

`Commands.prepare/4` prepares a review under the person's reviewer grant
for that key, and every other step under their operator grant
(`no_reviewer_grant`, `no_operator_grant`).

## Evidence files

Evidence is not named in advance, so the
[upload rule](2026-10-19-uploads.md) gains one case: an operator may store a
file as evidence for a task in progress
(`POST …/artifacts?evidence_for=<task_id>`), checked before any byte is
read. Each person may store at most **32 MiB** of evidence per task, two
full submissions (a submission verifies at most 16 MiB). Beyond that: 413
`quota_exceeded`. Each distinct file is charged once, so a retried upload
costs nothing more. Concurrent writes hold separate monitored reservations:
any successful write commits the digest; failures release only their own
reservation. Room is refunded only when all pending writes fail. The count
is held by one process for the cluster (`ArtifactCustody.Quota`).

Evidence stays out of the change feed, which carries only that a
submission and a review exist. The project's operators and reviewers read
it on demand; a suggester (an agent) does not:

```
GET …/tasks/:task_id/evidence
    → {submission_event_id, principal_id, evidence: {criterion: {digest, custody_receipt_id}}}
GET …/receipts/:receipt_id
    → the verified bytes, as an attachment
```

Files are served as `application/octet-stream` attachments with `nosniff`
and a sandboxing CSP, so nothing uploaded runs in the page's origin.

## Commands

```
POST /api/v1/chapters/:c/tenants/:t/projects/:p/commands
  {"action": "start", "task_id", "key_id"}
  {"action": "submit_evidence", "task_id", "custody_receipts": {criterion: receipt id}, "key_id"}
  {"action": "review", "task_id", "decision": "accept" | "refuse", "reason", "key_id"}
  {"action": "complete", "task_id", "review_event_id", "key_id"}
```

The server derives each criterion's evidence digest from its receipt and
the review's definition and submission from the task. The page signs only
if the decoded command names exactly what it shows: the receipts and
digests it stored, or the submission, decision and reason the reviewer
chose.

## The web view

- **Operator:** a ready task offers **Start**. In progress, **Submit
  evidence…** opens one file field per criterion; each file is hashed,
  stored, its custody signed (a receipt the project already holds for the
  same bytes is reused after an authorized read confirms availability; a
  missing file is uploaded again before that receipt is reused), then the submission is signed. The task then waits
  for a review. After a refusal it shows the reason and offers to submit
  again; after acceptance, **Complete**.
- **Reviewer:** "Evidence to review" lists others' unreviewed submissions,
  each criterion's file as a download, and **Accept** or **Refuse**, both
  asking for the reason recorded on the ledger. Own submissions are never
  listed.
- **This device:** the request form asks for the role. Each role's status
  is shown, and only roles not yet asked for are offered.

## Model

`spec/task_readiness.qnt` (now built on `spec/task_lifecycle.qnt`; see
[cancel and reopen](2026-10-19-cancel-reopen.md#model)) runs to `completed`, with two tasks (the
second waits for the first), two operators and two reviewers, one of whom
is also an operator. `safety` adds:

- **predecessors first:** a task is ready, in progress or completed only
  once its predecessors are completed;
- **completed on accepted work:** a completed task's evidence was submitted
  after it started and accepted by a reviewer other than the submitter;
- **reviewer is not submitter.**

Witnesses show a refused review in progress, a completed task, and the
successor becoming ready. Safety holds over 3,000 sampled runs and
exhaustively to depth 5. Mutants that allow self-review, keep evidence
across start, or skip the predecessor check each violate it.

## Verification

- **`CoopSubstrate.ExecutionTest`:**
  - start, evidence, review and complete, after which the successor can be
    ready (and not before);
  - completion needs an accepting review of the current submission:
    without one, after a refusal, and citing a review a resubmission
    cleared;
  - the starter's own acknowledgement, given once ready;
  - evidence refused while queued, and cleared by starting;
  - reviews by a reviewer device only, never one's own, once;
  - evidence storage only for a task in progress, within the quota;
  - evidence read by operators and reviewers only.
- **`EnrolmentsTest`:** reviewer requests, statuses per role, the reviewer
  grant, the administrator's check, reviewer feed access and revocation.
- **`SpruceGoose.Web.ExecutionTest`** over HTTP: the whole path with a
  reviewer device, evidence and download headers, and refusals (not named,
  no reviewer grant, review mismatch, invalid review, no grant, unknown
  receipt). **`DeviceTest`** and **`RevocationTest`:** a reviewer enrolled
  with `mix coop.enrol` and revoked with `mix coop.revoke`.
- **Node:** the next step in progress (evidence, waiting, refused,
  complete), what a reviewer sees, and enrolment statements bound to the
  role.
- **Browser (Chromium):** after ready, the person starts the task and
  submits a file as evidence. A second browser signs in as the reviewer,
  requests reviewer access (approved by code), downloads the file, and
  accepts it. The person completes the task. The ledger holds each step
  signed by the right device.
- **Mutation:** if the server prepares the review with a different reason,
  the reviewer's page refuses to sign and the browser test fails.

## Limits

- A reviewer device is revoked by governance (`mix coop.revoke`), not by
  its holder from the view.
- The evidence quota is in memory: it starts afresh if its process moves
  to another node, like the rate limits.
- A task whose starter leaves stays in progress; any operator in the
  project can still submit evidence and complete it.
- Stepping back from in progress and cancelling a task are now
  [offered](2026-10-19-cancel-reopen.md).
