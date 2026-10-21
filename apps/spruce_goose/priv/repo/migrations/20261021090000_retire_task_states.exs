defmodule SpruceGoose.Repo.Migrations.RetireTaskStates do
  @moduledoc """
  The task lifecycle is the ledger's (`TaskCore.TaskLifecycle`): `waiting`,
  `blocked` and `failed` are retired, so tasks in them would no longer load.
  Each moves to the state the ledger would hold it in:

    * `waiting` → `in_progress`: the work is under way. Its wait note goes.
    * `blocked`, `failed` → `queued`: readiness is re-established before the
      work starts again, as after a reopen.

  The predecessor guard is suspended for the move: a waiting task started
  once its predecessors were complete, and completion is absorbing.

  These moves are not certified, so `ledger replay-status` reports each moved
  task as a difference until its next certified mutation.
  """
  use Ecto.Migration

  def up, do: Enum.each(statements(), &execute/1)

  @doc false
  def statements do
    [
      "ALTER TABLE workflow_tasks DISABLE TRIGGER workflow_tasks_start_predecessor_guard",
      """
      UPDATE workflow_tasks
      SET state = CASE state WHEN 'waiting' THEN 'in_progress' ELSE 'queued' END,
          input = input - 'wait_reason',
          lock_version = lock_version + 1,
          updated_at = now()
      WHERE state IN ('waiting', 'blocked', 'failed')
      """,
      "ALTER TABLE workflow_tasks ENABLE TRIGGER workflow_tasks_start_predecessor_guard"
    ]
  end

  def down, do: :ok
end
