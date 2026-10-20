defmodule TaskCore.TaskLifecycle do
  @moduledoc """
  A task's lifecycle, version 1, as the signed ledger admits it
  (docs/architecture/2026-10-19-lifecycle.md, 2026-10-19-execution.md,
  2026-10-19-cancel-reopen.md).

  Every task is born in `inbox` and finishes in `completed` or `cancelled`,
  both absorbing. Reopening sends work under way back to `queued`, to be
  readied again. Each command admits a subset of this relation (an operator
  cancels only before the work starts; governance, until it completes); the
  relation is their union, and nothing else.

  This module is only the relation. Preconditions that depend on data (a
  Definition of Done, the SOP, predecessors, receipts, an accepting review)
  belong to the command that performs the move.
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
