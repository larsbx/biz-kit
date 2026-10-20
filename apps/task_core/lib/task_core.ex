defmodule TaskCore do
  @moduledoc """
  The core of task and workflow management, for any application that needs
  it (docs/architecture/2026-10-20-task-core.md). Pure: no processes, storage
  or I/O, and no dependencies.

    * `TaskCore.Lifecycle`: a versioned, finite, fail-closed state machine
      contract, verified when its declaration compiles;
    * `TaskCore.TaskLifecycle`: a task's states and moves, as the signed
      ledger admits them;
    * `TaskCore.Dag`: a workflow's dependency graph, validated and ordered;
    * `TaskCore.Admission` and `TaskCore.State`: whether an event may be
      appended, and the fold of those accepted, with the rules of
      `Readiness`, `DoD`, `Timing` and `Delegation`;
    * `TaskCore.Steps` and `TaskCore.Decisions`: the command a person signs;
    * `TaskCore.Host`: the two effects a host supplies.
  """
end
