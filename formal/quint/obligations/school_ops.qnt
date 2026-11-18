// school_ops: "Staff readiness tasks never assert learner mastery or
// authoritative assessment results".
// Abstracts SchoolOps.Workflows.validate/0 and plan/1, which normalize the
// school blueprint through TaskCore.Blueprint.normalize/1: exact_keys/4 refuses
// any task key outside the closed staff-work schema ("unknown or missing
// keys"), and SchoolOps.Workflows.references/1 / SchoolOps.Catalog.fetch/1 only
// resolve curriculum IDs (the catalog holds no learner records).
// Abstracted away: one proposed task per step with two optional extras — a
// learner-result field (e.g. a mastery or score key) and a learner-record
// reference. Free-text titles and descriptions are NOT checked by the code and
// are not modelled. GUARDED switches off the closed-key and catalog checks.
module school_ops_spec {
  const GUARDED: bool
  type Task = { learnerResult: bool, learnerRef: bool }

  var planned: Set[Task]
  var refused: int

  action init = all { planned' = Set(), refused' = 0 }

  action propose(learnerResult, learnerRef) = {
    val clean = not(learnerResult) and not(learnerRef)
    if (clean or not(GUARDED)) all {
      planned' = planned.union(Set({ learnerResult: learnerResult, learnerRef: learnerRef })),
      refused' = refused,
    } else all { planned' = planned, refused' = refused + 1 }
  }

  action step =
    nondet r = Set(true, false).oneOf()
    nondet l = Set(true, false).oneOf()
    propose(r, l)

  // No planned staff task carries a learner result or references a learner record.
  val obligation = planned.forall(t => not(t.learnerResult or t.learnerRef))
  // A staff task was planned and a learner-asserting proposal was refused.
  val obligationWitness = not(planned.size() > 0 and refused > 0)
}

module school_ops { import school_ops_spec(GUARDED = true).* }
module school_ops_control { import school_ops_spec(GUARDED = false).* }
