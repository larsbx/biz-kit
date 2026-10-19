// Task lifecycle from the inbox to `completed`, with the Definition of Done
// gate of docs/architecture/2026-10-14-ledger-task-readiness.md#definition-of-done-before-queuing
// and execution of docs/architecture/2026-10-19-execution.md. Every action is
// one admitted ledger command; its preconditions are the append gate's checks
// in Tasks.Readiness and Tasks.DoD.
//
//   ./check.sh   (typecheck, sampled safety, witnesses, bounded Apalache check)
module task_readiness {
  pure val TASKS = Set("t1", "t2")
  // t2 waits for t1: its readiness names t1 as a predecessor.
  pure val PREDECESSORS = Map("t1" -> Set(), "t2" -> Set("t1"))
  pure val OPERATORS = Set("alice", "bob")
  // alice also holds a reviewer grant, so a self-review can be attempted.
  pure val REVIEWERS = Set("alice", "carol")

  // `submitter` is "" without a submission; `review` is "none", "accept" or
  // "refuse"; `early` marks evidence submitted before the task was started.
  type Task = {
    state: str, dod: bool, readiness: bool, ack: bool,
    submitter: str, early: bool, review: str, reviewer: str,
  }

  pure val INBOX = {
    state: "inbox", dod: false, readiness: false, ack: false,
    submitter: "", early: false, review: "none", reviewer: "",
  }

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

  action step = any {
    propose, defineDoD, defineReadiness, acknowledge, queue, ready, start, submit, review, complete,
  }

  // No task is ever left unable to get a Definition of Done: it has one, or it
  // is still in a state where one can be defined.
  val doneIsDefinable = TASKS.forall(t =>
    val k = tasks.get(t)
    k.dod or Set("inbox", "proposed").contains(k.state))

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

  val safety = doneIsDefinable and readinessBeforeQueue and predecessorsFirst
    and completedOnAcceptedWork and reviewerIsNotSubmitter

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
