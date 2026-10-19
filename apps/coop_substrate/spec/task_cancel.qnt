// Cancelling and reopening tasks (docs/architecture/2026-10-19-cancel-reopen.md):
// the lifecycle of task_lifecycle.qnt with `cancel` (an operator before the
// work starts, governance up to completion) and `reopen` (in_progress ->
// queued) added. Its `safety` includes that cancelled is final and that each
// party cancels only where it may.
//
//   ./check.sh   (typecheck, sampled safety, witnesses, bounded Apalache check)
module task_cancel {
  import task_lifecycle.* from "./task_lifecycle"

  action step = any {
    propose, defineDoD, defineReadiness, acknowledge, queue, ready, start, submit, review, complete,
    cancel, reopen,
  }

  // -- witnesses: each must be violated, proving the state is reachable -----
  val noCancelledByOperator = TASKS.forall(t => tasks.get(t).cancelledBy != "operator")
  // Governance calls off work under way.
  val noCancelledInProgress = TASKS.forall(t => tasks.get(t).cancelledFrom != "in_progress")
  // Sent back to queued, to be readied again (readying and starting it again
  // is in CancelReopenTest).
  val noReopened = TASKS.forall(t =>
    not(tasks.get(t).state == "queued" and tasks.get(t).reopened))
  // A predecessor cancelled while its successor waits for it.
  val noSuccessorStranded = not(tasks.get("t1").state == "cancelled" and tasks.get("t2").state == "queued")
}
