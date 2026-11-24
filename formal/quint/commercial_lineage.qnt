// Commercial accounting lineage projection: only original recorded source
// starts originalOnly; assignment / discharge / legacy netting irreversibly
// make it false. A later assignment back cannot restore original provenance.
//
// This is an abstract deterministic read fold, not the source event/signature
// verifier, append gate, contract validity or Hawala financial authority.
module commercial_lineage_spec {
  const GUARDED: bool

  var originalOnly: bool
  var open: bool
  var revision: int
  var assignments: int
  var closedTransitions: int

  action init = all {
    originalOnly' = true,
    open' = true,
    revision' = 1,
    assignments' = 0,
    closedTransitions' = 0,
  }

  action assignment = all {
    open,
    originalOnly' = false,
    open' = open,
    revision' = revision + 1,
    assignments' = assignments + 1,
    closedTransitions' = closedTransitions,
  }

  // This path models assignment *back* after the first assignment.
  // In the intentionally faulty control, it incorrectly reclassifies a
  // derived claim as a fresh original business obligation.
  action assignmentBack = all {
    open,
    assignments >= 1,
    originalOnly' = if (GUARDED) false else true,
    open' = open,
    revision' = revision + 1,
    assignments' = assignments + 1,
    closedTransitions' = closedTransitions,
  }

  action discharge = all {
    open,
    originalOnly' = false,
    open' = false,
    revision' = revision + 1,
    assignments' = assignments,
    closedTransitions' = closedTransitions + 1,
  }

  action nettingClose = all {
    open,
    originalOnly' = false,
    open' = false,
    revision' = revision + 1,
    assignments' = assignments,
    closedTransitions' = closedTransitions + 1,
  }

  action crashRestart = all {
    originalOnly' = originalOnly,
    open' = open,
    revision' = revision,
    assignments' = assignments,
    closedTransitions' = closedTransitions,
  }

  action step = any {
    assignment,
    assignmentBack,
    discharge,
    nettingClose,
    crashRestart
  }

  val provenanceSafety =
    revision == 1 + assignments + closedTransitions
    and (assignments > 0 implies not(originalOnly))
    and (closedTransitions > 0 implies not(open) and not(originalOnly))
    and (originalOnly implies revision == 1 and open)

  val noAssignedWitness = not(assignments >= 1 and open and not(originalOnly))
  val noAssignBackWitness = not(assignments >= 2 and open and not(originalOnly))
  val noClosureWitness = not(closedTransitions >= 1 and not(open))
}

module commercial_lineage {
  import commercial_lineage_spec(GUARDED = true).*
}

module commercial_lineage_control {
  import commercial_lineage_spec(GUARDED = false).*
}
