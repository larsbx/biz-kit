// Task lifecycle from the inbox to `completed`, with the Definition of Done
// gate of docs/architecture/2026-10-14-ledger-task-readiness.md#definition-of-done-before-queuing
// execution of docs/architecture/2026-10-19-execution.md, and cancelling and
// reopening of docs/architecture/2026-10-19-cancel-reopen.md. Every action is
// one admitted ledger command; its preconditions are the append gate's checks
// in Tasks.Readiness and Tasks.DoD.
//
// A library: no step relation of its own. task_readiness.qnt checks the
// lifecycle to completion and task_cancel.qnt adds cancelling and reopening,
// each with this `safety` and its own witnesses.
module task_lifecycle {
  pure val TASKS = Set("t1", "t2")
  // t2 waits for t1: its readiness names t1 as a predecessor.
  pure val PREDECESSORS = Map("t1" -> Set(), "t2" -> Set("t1"))
  pure val OPERATORS = Set("alice", "bob")
  // alice also holds a reviewer grant, so a self-review can be attempted.
  pure val REVIEWERS = Set("alice", "carol")

  // `submitter` is "" without a submission; `review` is "none", "accept" or
  // "refuse"; `early` marks evidence submitted before the task was started.
  // `cancelledBy` is "", "operator" or "governance" and `cancelledFrom` the
  // state it was cancelled in; `reopened` marks a task once sent back. No
  // action clears them, so they record what happened.
  type Task = {
    state: str, dod: bool, readiness: bool, ack: bool,
    submitter: str, early: bool, review: str, reviewer: str,
    cancelledBy: str, cancelledFrom: str, reopened: bool,
  }

  pure val INBOX = {
    state: "inbox", dod: false, readiness: false, ack: false,
    submitter: "", early: false, review: "none", reviewer: "",
    cancelledBy: "", cancelledFrom: "", reopened: false,
  }

  pure val BEFORE_WORK = Set("inbox", "proposed", "queued", "ready")

  var tasks: str -> Task

  action init = tasks' = TASKS.mapBy(_ => INBOX)

  action change(t: str, f: Task => Task): bool = tasks' = tasks.setBy(t, f)

  // inbox -> proposed (TaskProposedV1).
  action propose = {
    nondet t = TASKS.oneOf()
    all { tasks.get(t).state == "inbox", change(t, x => { ...x, state: "proposed" }) }
  }

  // A Definition of Done is defined only while a task is proposed (Tasks.DoD).
  action defineDoD = {
    nondet t = TASKS.oneOf()
    all { tasks.get(t).state == "proposed", change(t, x => { ...x, dod: true }) }
  }

  // Governance readiness definition, while proposed or queued (Tasks.Readiness).
  // Replacing requirements invalidates an earlier SOP acknowledgment.
  action defineReadiness = {
    nondet t = TASKS.oneOf()
    all {
      Set("proposed", "queued").contains(tasks.get(t).state),
      change(t, x => { ...x, readiness: true, ack: false }),
    }
  }

  // Also once ready, so that whoever starts can acknowledge on their device.
  action acknowledge = {
    nondet t = TASKS.oneOf()
    val k = tasks.get(t)
    all {
      Set("proposed", "queued", "ready").contains(k.state),
      k.readiness,
      change(t, x => { ...x, ack: true }),
    }
  }

  // proposed -> queued: the DoD gate, then the readiness prerequisites.
  action queue = {
    nondet t = TASKS.oneOf()
    val k = tasks.get(t)
    all { k.state == "proposed", k.dod, k.readiness, k.ack, change(t, x => { ...x, state: "queued" }) }
  }

  def completed(t: str): bool = tasks.get(t).state == "completed"

  // queued -> ready, once every predecessor is completed. Input receipts are
  // not modelled here.
  action ready = {
    nondet t = TASKS.oneOf()
    val k = tasks.get(t)
    all {
      k.state == "queued", k.readiness, k.ack,
      PREDECESSORS.get(t).forall(p => completed(p)),
      change(t, x => { ...x, state: "ready" }),
    }
  }

  // ready -> in_progress (TaskStartedV1): clears any earlier evidence.
  action start = {
    nondet t = TASKS.oneOf()
    val k = tasks.get(t)
    all {
      k.state == "ready", k.ack,
      change(t, x => { ...x, state: "in_progress", submitter: "", early: false, review: "none", reviewer: "" }),
    }
  }

  // Evidence (TaskEvidenceSubmittedV2) while proposed or in progress; a new
  // submission clears the review.
  action submit = {
    nondet t = TASKS.oneOf()
    nondet who = OPERATORS.oneOf()
    val k = tasks.get(t)
    all {
      Set("proposed", "in_progress").contains(k.state), k.dod,
      change(t, x => { ...x, submitter: who, early: k.state == "proposed", review: "none", reviewer: "" }),
    }
  }

  // One review of the current submission, by a reviewer who did not submit it.
  action review = {
    nondet t = TASKS.oneOf()
    nondet who = REVIEWERS.oneOf()
    nondet decision = Set("accept", "refuse").oneOf()
    val k = tasks.get(t)
    all {
      Set("proposed", "in_progress").contains(k.state),
      k.submitter != "", k.review == "none", who != k.submitter,
      change(t, x => { ...x, review: decision, reviewer: who }),
    }
  }

  // in_progress -> completed (TaskCompletedV1), citing the accepting review.
  action complete = {
    nondet t = TASKS.oneOf()
    val k = tasks.get(t)
    all { k.state == "in_progress", k.review == "accept", change(t, x => { ...x, state: "completed" }) }
  }

  // TaskCancelledV1 by an operator before the work starts, or
  // TaskCancelledByGovernanceV1 from any state short of completed.
  action cancel = {
    nondet t = TASKS.oneOf()
    nondet by = Set("operator", "governance").oneOf()
    val k = tasks.get(t)
    all {
      if (by == "operator") BEFORE_WORK.contains(k.state)
      else BEFORE_WORK.union(Set("in_progress")).contains(k.state),
      change(t, x => { ...x, state: "cancelled", cancelledBy: by, cancelledFrom: k.state }),
    }
  }

  // in_progress -> queued (TaskReopenedV1): the work is cleared.
  action reopen = {
    nondet t = TASKS.oneOf()
    all {
      tasks.get(t).state == "in_progress",
      change(t, x => { ...x, state: "queued", submitter: "", early: false, review: "none", reviewer: "", reopened: true }),
    }
  }

  // No task is ever left unable to get a Definition of Done: it has one, it
  // is still in a state where one can be defined, or it was cancelled and
  // needs none.
  val doneIsDefinable = TASKS.forall(t =>
    val k = tasks.get(t)
    k.dod or Set("inbox", "proposed", "cancelled").contains(k.state))

  // Readiness was defined for every task past `proposed`.
  val readinessBeforeQueue = TASKS.forall(t =>
    val k = tasks.get(t)
    Set("queued", "ready", "in_progress", "completed").contains(k.state) implies k.readiness)

  // A task is ready, under way or done only once its predecessors are done.
  val predecessorsFirst = TASKS.forall(t =>
    Set("ready", "in_progress", "completed").contains(tasks.get(t).state)
      implies PREDECESSORS.get(t).forall(p => completed(p)))

  // Completed only on evidence submitted after it started, accepted by a
  // reviewer other than the submitter.
  val completedOnAcceptedWork = TASKS.forall(t =>
    val k = tasks.get(t)
    k.state == "completed" implies
      (k.submitter != "" and not(k.early) and k.review == "accept" and k.reviewer != k.submitter))

  val reviewerIsNotSubmitter = TASKS.forall(t =>
    val k = tasks.get(t)
    k.review != "none" implies k.reviewer != k.submitter)

  // Cancelled is final: a task once cancelled is still cancelled.
  val cancelledIsFinal = TASKS.forall(t =>
    val k = tasks.get(t)
    k.cancelledBy != "" implies k.state == "cancelled")

  // A person cancels only before the work starts; nobody cancels a completed task.
  val cancelledFromAllowedState = TASKS.forall(t =>
    val k = tasks.get(t)
    (k.cancelledBy == "operator" implies BEFORE_WORK.contains(k.cancelledFrom))
      and (k.cancelledBy != "" implies k.cancelledFrom != "completed"))

  val safety = doneIsDefinable and readinessBeforeQueue and predecessorsFirst
    and completedOnAcceptedWork and reviewerIsNotSubmitter
    and cancelledIsFinal and cancelledFromAllowedState
}
