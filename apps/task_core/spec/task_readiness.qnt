// The task lifecycle from the inbox to `completed` (task_lifecycle.qnt),
// without cancelling or reopening: the Definition of Done gate of
// docs/architecture/2026-10-14-ledger-task-readiness.md#definition-of-done-before-queuing
// and execution of docs/architecture/2026-10-19-execution.md.
//
//   ./check.sh   (typecheck, sampled safety, witnesses, bounded Apalache check)
module task_readiness {
  import task_lifecycle.* from "./task_lifecycle"

  // Without cancelling and reopening (task_cancel.qnt adds them), so that
  // random runs still reach a successor becoming ready.
  action step = any {
    propose, defineDoD, defineReadiness, acknowledge, queue, ready, start, submit, review, complete,
  }

  // -- witnesses: each must be violated, proving the state is reachable -----
  val noQueued = TASKS.forall(t => tasks.get(t).state != "queued")
  val noReady = TASKS.forall(t => tasks.get(t).state != "ready")
  val noQueuedAwaitingAck = TASKS.forall(t => not(tasks.get(t).state == "queued" and not(tasks.get(t).ack)))
  val noRefusedInProgress = TASKS.forall(t =>
    not(tasks.get(t).state == "in_progress" and tasks.get(t).review == "refuse"))
  val noCompleted = TASKS.forall(t => not(completed(t)))
  // The successor becomes ready: completion is what readiness waits for.
  val noSuccessorReady = tasks.get("t2").state != "ready"
}
