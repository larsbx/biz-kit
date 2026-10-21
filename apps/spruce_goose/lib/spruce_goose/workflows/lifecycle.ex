defmodule SpruceGoose.Workflows.Lifecycle do
  @moduledoc """
  Versioned, fail-closed task lifecycle contract.

  The ledger's relation (`TaskCore.TaskLifecycle`): every task is born in
  `inbox` and finishes in `completed` or `cancelled`, the only absorbing
  states. Reopening sends work under way back to `queued`, so that readiness
  is re-established before it starts again.

  This module is only the relation. Preconditions that depend on data (the
  SOP gate, predecessor completion, artifact receipts, TODO completion, the
  reason a task is reopened or cancelled) are enforced by the `Task`
  resource's `:transition` action.
  """

  use TaskCore.Lifecycle,
    version: 1,
    initial: :inbox,
    transitions: [
      inbox: [:proposed, :cancelled],
      proposed: [:queued, :cancelled],
      queued: [:ready, :cancelled],
      ready: [:in_progress, :cancelled],
      in_progress: [:completed, :queued, :cancelled],
      completed: [],
      cancelled: []
    ]
end
