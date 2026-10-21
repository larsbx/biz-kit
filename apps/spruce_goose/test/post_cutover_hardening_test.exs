defmodule SpruceGoose.PostCutoverHardeningTest do
  use SpruceGoose.DataCase, async: false

  alias SpruceGoose.CLI.Executor
  alias SpruceGoose.Workflows.{Definition, Project, Roadmap, Task, Workflow}

  test "PC-01: completed authority cutover is immutable and import stays disabled" do
    previous_root = Application.get_env(:spruce_goose, :ledger_import_root)
    previous_recovery = Application.get_env(:spruce_goose, :ledger_recovery_mode)
    previous_database = Application.get_env(:spruce_goose, :ledger_recovery_database)
    Application.put_env(:spruce_goose, :ledger_import_root, "/home/admin-papa/tasks")
    Application.put_env(:spruce_goose, :ledger_recovery_mode, true)
    Application.put_env(:spruce_goose, :ledger_recovery_database, Repo.config()[:database])

    on_exit(fn ->
      restore(:ledger_import_root, previous_root)
      restore(:ledger_recovery_mode, previous_recovery)
      restore(:ledger_recovery_database, previous_database)
    end)

    Repo.query!(
      "UPDATE spruce_goose_authority SET mode = 'ash', cutover_at = now() WHERE id = TRUE"
    )

    assert {:error, %Postgrex.Error{}} =
             Repo.query("UPDATE spruce_goose_authority SET mode = 'tuxedo' WHERE id = TRUE")

    assert {:error, %Postgrex.Error{}} =
             Repo.query("UPDATE spruce_goose_authority SET cutover_at = NULL WHERE id = TRUE")

    assert {:error, "ledger import is disabled while ash is authoritative"} =
             Executor.run({:import_ledger, "/home/admin-papa/tasks/todo.txt"})
  end

  defp restore(key, nil), do: Application.delete_env(:spruce_goose, key)
  defp restore(key, value), do: Application.put_env(:spruce_goose, key, value)

  test "PC-02/06: terminal TODO admission fails and concurrent admission is race-free" do
    %{task: task} = fixture("todos")
    task = advance(task, [:proposed, :queued, :ready, :in_progress, :completed])

    assert {:error, _} = Executor.run({:add_todo, task.task_id, "too late"})

    assert {:error, %Postgrex.Error{}} =
             Repo.query(
               """
               INSERT INTO task_todos
                 (id, task_id, todo_id, body, position, completed, inserted_at, updated_at)
               VALUES (gen_random_uuid(), $1::text::uuid, 'late', 'late', 1, FALSE, now(), now())
               """,
               [task.id]
             )

    %{task: open_task} = fixture("todo-race")

    results =
      1..8
      |> Elixir.Task.async_stream(
        fn _ -> Executor.run({:add_todo, open_task.task_id, "same body"}) end,
        max_concurrency: 8
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, _}, &1))

    # Record identity is generated, not derived from sha256(body). Eight
    # concurrent admissions of identical text are eight distinct checklist
    # items, not one. The advisory lock still serializes them, so positions
    # are contiguous and unique rather than colliding.
    ids = Enum.map(results, fn {:ok, todo} -> todo.id end)
    assert ids |> Enum.uniq() |> length() == 8

    positions = Enum.map(results, fn {:ok, todo} -> todo.position end)
    assert Enum.sort(positions) == Enum.to_list(1..8)

    %{task: different_task} = fixture("todo-different")

    positions =
      ["first", "second"]
      |> Elixir.Task.async_stream(
        fn body -> Executor.run({:add_todo, different_task.task_id, body}) end,
        max_concurrency: 2
      )
      |> Enum.map(fn {:ok, {:ok, todo}} -> todo.position end)

    assert Enum.sort(positions) == [1, 2]

    %{task: racing_task} = fixture("todo-completion-race")
    racing_task = advance(racing_task, [:proposed, :queued, :ready, :in_progress])

    race_results =
      [
        fn ->
          Repo.query(
            "UPDATE workflow_tasks SET state = 'completed' WHERE id = $1::text::uuid",
            [racing_task.id]
          )
        end,
        fn ->
          Repo.query(
            """
            INSERT INTO task_todos
              (id, task_id, todo_id, body, position, completed, inserted_at, updated_at)
            VALUES (gen_random_uuid(), $1::text::uuid, 'race', 'race', 1, FALSE, now(), now())
            """,
            [racing_task.id]
          )
        end
      ]
      |> Elixir.Task.async_stream(fn operation -> operation.() end, max_concurrency: 2)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(race_results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(race_results, &match?({:error, _}, &1)) == 1

    assert %{rows: [[false]]} =
             Repo.query!(
               """
               SELECT task.state = 'completed' AND EXISTS (
                 SELECT 1 FROM task_todos todo
                 WHERE todo.task_id = task.id AND todo.completed = FALSE
               )
               FROM workflow_tasks task
               WHERE task.id = $1::text::uuid
               """,
               [racing_task.id]
             )
  end

  test "PC-07/09: reasons and bounded typed metadata fail closed" do
    %{task: task} = fixture("validation")

    assert {:error, _} = Ash.update(task, %{to_state: :cancelled}, action: :transition)

    for metadata <- [
          %{priority: -1},
          %{priority: 6},
          %{rank: String.duplicate("x", 129)},
          %{due_at: "not-a-date"},
          %{labels: List.duplicate("x", 51)},
          %{custom_fields: %{"date" => %{"type" => "date", "value" => "yesterday"}}}
        ] do
      case Ash.update(task, metadata, action: :update_board_metadata) do
        {:error, _} -> :ok
        {:ok, _} -> flunk("metadata unexpectedly accepted: #{inspect(metadata)}")
      end
    end
  end

  test "PC-05: the canonical CLI updates a task's typed metadata" do
    %{task: task} = fixture("cli")

    assert {:ok, updated} =
             Executor.run({
               :update_task_metadata,
               task.task_id,
               ~s({"priority":2,"assignees":["jimbo"],"labels":["audit"]})
             })

    assert {updated.priority, updated.assignees, updated.labels} == {2, ["jimbo"], ["audit"]}

    assert {:error, "metadata contains unsupported keys"} =
             Executor.run({:update_task_metadata, task.task_id, ~s({"board_id":"x"})})
  end

  defp fixture(suffix) do
    {:ok, project} = Ash.create(Project, %{key: "pc-#{suffix}", name: "PC #{suffix}"})

    {:ok, roadmap} =
      Ash.create(Roadmap, %{
        project_id: project.id,
        key: "pc-#{suffix}",
        name: "PC #{suffix}"
      })

    {:ok, definition} = Definition.parse(%{tasks: [%{id: suffix, kind: :oban}]})

    {:ok, workflow} =
      Ash.create(Workflow, %{
        roadmap_id: roadmap.id,
        workflow_id: "pc-#{suffix}",
        name: "PC #{suffix}",
        definition: definition
      })

    {:ok, task} =
      Ash.create(Task, %{
        workflow_id: workflow.id,
        task_id:
          "tsk-20260727T191000Z-#{String.slice(:crypto.hash(:sha256, suffix) |> Base.encode16(case: :lower), 0, 8)}",
        title: "PC #{suffix}",
        definition_of_done: "Post-cutover invariant holds",
        runner: :oban
      })

    %{
      project: project,
      roadmap: roadmap,
      workflow: workflow,
      task: task
    }
  end

  defp advance(task, states) do
    Enum.reduce(states, task, fn state, current ->
      {:ok, current} = Ash.update(current, %{to_state: state}, action: :transition)
      current
    end)
  end
end
