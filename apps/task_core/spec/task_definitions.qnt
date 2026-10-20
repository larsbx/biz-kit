// Readiness definitions across a project (TaskCore.Readiness;
// docs/architecture/2026-10-20-sprucegoose-salvage.md): governance defines and
// redefines each task's predecessors and SOP. No definition closes a
// predecessor cycle (I-19), so no task is left unable ever to become ready,
// and once a task's SOP is versioned its version never goes back and one
// version names one document (I-20).
//
//   ./check.sh   (typecheck, sampled safety, witnesses, bounded Apalache check)
module task_definitions {
  pure val TASKS = Set("t1", "t2", "t3")
  // SOP documents and the versions governance may name; 0 is "unversioned".
  pure val DOCUMENTS = Set("d1", "d2")
  pure val VERSIONS = Set(0, 1, 2)

  type Definition = { defined: bool, preds: Set[str], doc: str, version: int }

  var defs: str -> Definition
  // The highest version each task's SOP has been named at, and the document
  // each (task, version) first named: what I-20 is judged against.
  var highest: str -> int
  var named: (str, int) -> str

  action init = all {
    defs' = TASKS.mapBy(_ => { defined: false, preds: Set(), doc: "", version: 0 }),
    highest' = TASKS.mapBy(_ => 0),
    named' = Map(),
  }

  // Tasks reachable from `t` along predecessors, within |TASKS| steps.
  def reach(preds: str -> Set[str], t: str): Set[str] = {
    val one = preds.get(t)
    val two = one.union(flatten(one.map(u => preds.get(u))))
    two.union(flatten(two.map(u => preds.get(u))))
  }

  def acyclic(preds: str -> Set[str]): bool = TASKS.forall(t => not(reach(preds, t).contains(t)))

  def predsOf: str -> Set[str] = TASKS.mapBy(t => defs.get(t).preds)

  // The SOP rule of TaskReadinessDefinedV1: unversioned before, anything;
  // versioned before, a version at least as high, the same document at the
  // same version.
  def sopAllowed(t: str, doc: str, version: int): bool = {
    val old = defs.get(t)
    if (old.version == 0) true
    else version >= old.version and (version == old.version implies doc == old.doc)
  }

  action define = {
    nondet t = TASKS.oneOf()
    nondet preds = TASKS.exclude(Set(t)).powerset().oneOf()
    nondet doc = DOCUMENTS.oneOf()
    nondet version = VERSIONS.oneOf()
    all {
      acyclic(predsOf.set(t, preds)),
      sopAllowed(t, doc, version),
      defs' = defs.set(t, { defined: true, preds: preds, doc: doc, version: version }),
      highest' = highest.set(t, if (version > highest.get(t)) version else highest.get(t)),
      named' = if (version > 0 and not(named.keys().contains((t, version)))) named.put((t, version), doc) else named,
    }
  }

  action step = define

  // -- safety -------------------------------------------------------------------

  val predecessorsNeverCycle = acyclic(predsOf)

  // Once versioned, the current version is the highest it has been named at.
  val versionNeverRegresses = TASKS.forall(t =>
    highest.get(t) > 0 implies defs.get(t).version == highest.get(t))

  val oneVersionOneDocument = TASKS.forall(t =>
    val d = defs.get(t)
    d.version > 0 implies named.get((t, d.version)) == d.doc)

  val safety = predecessorsNeverCycle and versionNeverRegresses and oneVersionOneDocument

  // -- witnesses: each must be violated, proving the state is reachable -----
  val noChain = not(TASKS.exists(t => reach(predsOf, t).size() == 2))
  val noUpgrade = not(TASKS.exists(t => defs.get(t).version == 2 and named.keys().contains((t, 1))))
  val noRedefinedPredecessors = not(TASKS.exists(t => defs.get(t).defined and defs.get(t).preds == Set() and highest.get(t) > 0))
}
