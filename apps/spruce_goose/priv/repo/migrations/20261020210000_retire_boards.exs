defmodule SpruceGoose.Repo.Migrations.RetireBoards do
  @moduledoc """
  Boards, columns, saved filters and inbox captures are retired
  (docs/architecture/2026-10-20-sprucegoose-salvage.md).

    * `SpruceGoose.Workflows.RevisionTarget` no longer names a board, column
      or filter, so revisions targeting one would no longer load: they are
      removed.
    * Nothing keeps a task's column in step with its state any more, so the
      trigger requiring them to agree would refuse every transition of a task
      placed on a board: it is dropped. Existing placements stay as inert data.

  The tables stay until the legacy writer's database is retired.
  """
  use Ecto.Migration

  def up do
    execute("DELETE FROM revisions WHERE target_kind IN ('board', 'column', 'filter')")
    execute("DROP TRIGGER IF EXISTS workflow_tasks_board_membership ON workflow_tasks")
    execute("DROP FUNCTION IF EXISTS enforce_task_board_membership()")
  end

  def down, do: :ok
end
