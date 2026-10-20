// Blueprint-created tasks start with a DoD. Reuse the exact ledger task
// relation, evidence/review gates and fixed t2 -> t1 prerequisite. This is a
// bounded two-task, two-revision abstraction, not a proof of Git verification
// or the unbounded blueprint parser. Invalid revisions/versions are disabled.
module task_blueprint {
  import task_lifecycle as L from "./task_lifecycle"

  var revision: int
  var runRevision: int
  var instantiated: bool
  var startedUnder: int
  var runVersion: int

  action init = all {
    L::init,
    revision' = 0,
    runRevision' = 0,
    instantiated' = false,
    startedUnder' = 0,
    runVersion' = 0,
  }

  action applyBlueprint = all {
    revision < 2,
    revision' = revision + 1,
    runRevision' = runRevision,
    instantiated' = instantiated,
    startedUnder' = startedUnder,
    runVersion' = runVersion,
    L::tasks' = L::tasks,
  }

  action instantiate = {
    nondet requested = Set(0, 1, 2).oneOf()
    nondet version = Set(1, 2).oneOf()
    all {
      not(instantiated), revision > 0, requested == revision, version == 1,
      instantiated' = true,
      startedUnder' = revision,
      runVersion' = version,
      runRevision' = requested,
      revision' = revision,
      L::tasks' = L::TASKS.mapBy(_ => { ...L::INBOX, dod: true }),
    }
  }

  action work = all {
    instantiated,
    any {
      L::propose, L::defineDoD, L::defineReadiness, L::acknowledge,
      L::queue, L::ready, L::start, L::submit, L::review, L::complete,
    },
    revision' = revision,
    runRevision' = runRevision,
    instantiated' = instantiated,
    startedUnder' = startedUnder,
    runVersion' = runVersion,
  }

  action step = any { applyBlueprint, instantiate, work }

  val safety = L::safety and
    (instantiated implies (runRevision > 0 and runRevision <= revision and
      runRevision == startedUnder and runVersion == 1 and
      L::TASKS.forall(t => L::tasks.get(t).dod)))

  val noInstantiated = not(instantiated)
  val noSupersededRun = not(instantiated and runRevision < revision)
  val noSuccessorReady = L::tasks.get("t2").state != "ready"
}
