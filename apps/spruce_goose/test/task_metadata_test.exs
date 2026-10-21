defmodule SpruceGoose.TaskMetadataTest do
  @moduledoc """
  A task's typed metadata (rank, priority, assignees, labels, custom fields),
  revised under its own optimistic lock. Boards, columns and saved filters
  are retired (docs/architecture/2026-10-20-sprucegoose-salvage.md).
  """
  use SpruceGoose.DataCase, async: false

  alias SpruceGoose.Workflows.{
    Definition,
    Project,
    Roadmap,
    Task,
    Workflow
  }

  test "typed metadata and custom fields persist" do
    task = fixture("metadata")

    custom_fields = %{
      "estimate" => %{"type" => "number", "value" => 3},
      "customer_visible" => %{"type" => "boolean", "value" => true}
    }

    assert {:ok, updated} =
             Ash.update(
               task,
               %{
                 rank: "a0",
                 priority: 2,
                 assignees: ["agent:jimbo"],
                 labels: ["roadmap", "kanban"],
                 custom_fields: custom_fields
               },
               action: :update_board_metadata
             )

    assert updated.board_revision == 2
    assert updated.custom_fields == custom_fields
    assert updated.assignees == ["agent:jimbo"]
    assert updated.labels == ["roadmap", "kanban"]
  end

  test "concurrent metadata edits reject a stale revision" do
    task = fixture("concurrency")

    updates =
      ["first", "second"]
      |> Elixir.Task.async_stream(
        fn rank ->
          Ash.update(
            task,
            %{rank: rank},
            action: :update_board_metadata
          )
        end,
        max_concurrency: 2
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(updates, &match?({:ok, _}, &1)) == 1
    assert Enum.count(updates, &match?({:error, _}, &1)) == 1

    assert Enum.any?(updates, fn
             {:error, error} -> Exception.message(error) =~ "stale"
             _ -> false
           end)
  end

  test "invalid custom values fail closed" do
    task = fixture("validation")

    assert {:error, custom_error} =
             Ash.update(
               task,
               %{
                 custom_fields: %{"estimate" => %{"type" => "number", "value" => "three"}}
               },
               action: :update_board_metadata
             )

    assert Exception.message(custom_error) =~ "invalid typed value"
  end

  test "a task placed on a retired board still moves through its lifecycle" do
    task = fixture("placed")

    # A placement made before boards were retired, written as the old CLI did.
    %{rows: [[board_id]]} =
      Repo.query!(
        "INSERT INTO boards (id, workflow_id, key, name) VALUES (gen_random_uuid(), $1::text::uuid, 'main', 'Main') RETURNING id::text",
        [task.workflow_id]
      )

    %{rows: [[column_id]]} =
      Repo.query!(
        "INSERT INTO board_columns (id, board_id, key, name, position, task_state) VALUES (gen_random_uuid(), $1::text::uuid, 'inbox', 'Inbox', 1, 'inbox') RETURNING id::text",
        [board_id]
      )

    Repo.query!(
      "UPDATE workflow_tasks SET board_id = $1::text::uuid, column_id = $2::text::uuid WHERE id = $3::text::uuid",
      [board_id, column_id, task.id]
    )

    task = Ash.get!(Task, task.id)

    assert {:ok, %{state: :proposed}} =
             Ash.update(task, %{to_state: :proposed}, action: :transition)
  end

  test "the unified task model has no parallel issue resource or table" do
    refute Code.ensure_loaded?(SpruceGoose.Workflows.Issue)

    assert %{rows: [[nil]]} =
             Repo.query!("SELECT to_regclass('public.issues')")
  end

  defp fixture(suffix) do
    {:ok, project} =
      Ash.create(Project, %{key: "project-#{suffix}", name: "Project #{suffix}"})

    {:ok, roadmap} =
      Ash.create(Roadmap, %{
        project_id: project.id,
        key: "roadmap-#{suffix}",
        name: "Roadmap #{suffix}"
      })

    {:ok, definition} =
      Definition.parse(%{tasks: [%{id: "task-#{suffix}", kind: :oban}]})

    {:ok, workflow} =
      Ash.create(Workflow, %{
        roadmap_id: roadmap.id,
        workflow_id: "workflow-#{suffix}",
        name: "Workflow #{suffix}",
        definition: definition
      })

    {:ok, task} =
      Ash.create(Task, %{
        workflow_id: workflow.id,
        task_id:
          "tsk-20260727T150000Z-#{String.slice(:crypto.hash(:sha256, suffix) |> Base.encode16(case: :lower), 0, 8)}",
        title: "Task #{suffix}",
        definition_of_done: "Metadata tests pass",
        runner: :oban
      })

    task
  end
end
