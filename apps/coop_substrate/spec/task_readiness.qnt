// Task lifecycle up to `ready`, with the Definition of Done gate of
// docs/architecture/2026-10-14-ledger-task-readiness.md#definition-of-done-before-queuing.
// Every action is one admitted ledger command; its preconditions are the
// append gate's checks in Tasks.Readiness and Tasks.DoD.
//
//   ./check.sh   (typecheck, sampled safety, witnesses, bounded Apalache check)
module task_readiness {
  pure val TASKS = Set("t1", "t2")

  type Task = { state: str, dod: bool, readiness: bool, ack: bool }

  pure val INBOX = { state: "inbox", dod: false, readiness: false, ack: false }

  var tasks: str -> Task

  action init = tasks' = TASKS.mapBy(_ => INBOX)

  action change(t: str, f: Task => Task): bool = tasks' = tasks.setBy(t, f)

  // inbox -> proposed (TaskProposedV1).
  action propose = {
    nondet t = TASKS.oneOf()
    all { tasks.get(t).state == "inbox", change(t, x => { ...x, state: "proposed" }) }
  }

  // Every DoD command is admitted only while a task is proposed (Tasks.DoD).
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

  action acknowledge = {
    nondet t = TASKS.oneOf()
    val k = tasks.get(t)
    all { Set("proposed", "queued").contains(k.state), k.readiness, change(t, x => { ...x, ack: true }) }
  }

  // proposed -> queued: the DoD gate, then the readiness prerequisites.
  action queue = {
    nondet t = TASKS.oneOf()
    val k = tasks.get(t)
    all { k.state == "proposed", k.dod, k.readiness, k.ack, change(t, x => { ...x, state: "queued" }) }
  }

  // queued -> ready. Predecessors and input receipts are not modelled here.
  action ready = {
    nondet t = TASKS.oneOf()
    val k = tasks.get(t)
    all { k.state == "queued", k.readiness, k.ack, change(t, x => { ...x, state: "ready" }) }
  }

  action step = any { propose, defineDoD, defineReadiness, acknowledge, queue, ready }

  // No task is ever left unable to get a Definition of Done: it has one, or it
  // is still in a state where one can be defined.
  val doneIsDefinable = TASKS.forall(t =>
    val k = tasks.get(t)
    k.dod or Set("inbox", "proposed").contains(k.state))

  // Readiness was defined for every task past `proposed`.
  val readinessBeforeQueue = TASKS.forall(t =>
    val k = tasks.get(t)
    Set("queued", "ready").contains(k.state) implies k.readiness)

  val safety = doneIsDefinable and readinessBeforeQueue

  // -- witnesses: each must be violated, proving the state is reachable -----
  val noQueued = TASKS.forall(t => tasks.get(t).state != "queued")
  val noReady = TASKS.forall(t => tasks.get(t).state != "ready")
  val noQueuedAwaitingAck = TASKS.forall(t => not(tasks.get(t).state == "queued" and not(tasks.get(t).ack)))
}
