// task_core: "Revoked grants or changed task versions invalidate runnable agent intents".
// Abstracts TaskCore.AgentRuns.runnable?/2, which the execution adapter must
// re-call against fresh committed state before acting: the run must be open
// (run_open/1), its operator grant active in the same scope
// (active_operator/2, else :agent_run_operator_revoked), and
// TaskCore.AgentCandidates.plan/2 must find the suggester grant valid and a
// ticket matching the run's expected_task_version (matched_ticket/2, else
// :stale_agent_run_task).
// Abstracted away: one run on one task; scope, source event, DoD digest and
// the execution profile are omitted; versions are 1..3. GUARDED switches off
// the grant and version re-checks (run_open stays).
module task_core_spec {
  const GUARDED: bool
  type Dispatch = { operator: bool, suggester: bool, pinned: int, current: int }

  var operatorActive: bool
  var suggesterActive: bool
  var taskVersion: int
  var runOpen: bool
  var dispatched: Set[Dispatch]
  var refused: bool

  action init = all {
    operatorActive' = true, suggesterActive' = true, taskVersion' = 1,
    runOpen' = true, dispatched' = Set(), refused' = false,
  }

  action unchanged_but(op, sg, v, ro) = all {
    operatorActive' = op, suggesterActive' = sg, taskVersion' = v, runOpen' = ro,
    dispatched' = dispatched, refused' = refused,
  }

  action revokeOperator = unchanged_but(false, suggesterActive, taskVersion, runOpen)
  action revokeSuggester = unchanged_but(operatorActive, false, taskVersion, runOpen)
  action reviseTask = all { taskVersion < 3, unchanged_but(operatorActive, suggesterActive, taskVersion + 1, runOpen) }
  action cancelRun = unchanged_but(operatorActive, suggesterActive, taskVersion, false)

  // The run pinned expected_task_version = 1 when it was requested.
  action dispatch = {
    val valid = operatorActive and suggesterActive and taskVersion == 1
    all {
      runOpen,
      operatorActive' = operatorActive, suggesterActive' = suggesterActive,
      taskVersion' = taskVersion, runOpen' = runOpen,
      if (valid or not(GUARDED)) all {
        dispatched' = dispatched.union(Set({ operator: operatorActive, suggester: suggesterActive,
                                             pinned: 1, current: taskVersion })),
        refused' = refused,
      } else all { dispatched' = dispatched, refused' = true },
    }
  }

  action step = any { revokeOperator, revokeSuggester, reviseTask, cancelRun, dispatch }

  // Every dispatch held both grants and the task was still at the pinned version.
  val obligation = dispatched.forall(d => d.operator and d.suggester and d.pinned == d.current)
  // The intent ran, and later a dispatch was refused after a revocation or revision.
  val obligationWitness = not(dispatched.size() > 0 and refused)
}

module task_core { import task_core_spec(GUARDED = true).* }
module task_core_control { import task_core_spec(GUARDED = false).* }
