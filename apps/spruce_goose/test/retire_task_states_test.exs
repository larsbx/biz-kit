defmodule SpruceGoose.RetireTaskStatesTest do
  use SpruceGoose.DataCase, async: false

  alias SpruceGoose.Workflows.{Definition, Dependency, Project, Roadmap, Task, Workflow}

  test "retiring waiting, blocked and failed moves each task to the ledger's state" do
    %{first: first, second: second, third: third} = fixture()

    for {predecessor, successor} <- [{first, second}, {second, third}] do
      assert {:ok, _} =
               Ash.create(Dependency, %{
                 predecessor_id: predecessor.id,
                 successor_id: successor.id
               })
    end

    for {task, state} <- [{first, "blocked"}, {second, "waiting"}, {third, "failed"}] do
      Repo.query!(
        "UPDATE workflow_tasks SET state = $2, input = '{\"wait_reason\": \"held\"}' WHERE id = $1",
        [Ecto.UUID.dump!(task.id), state]
      )
    end

    migration = SpruceGoose.Repo.Migrations.RetireTaskStates

    unless Code.ensure_loaded?(migration),
      do:
        Code.require_file(
          "../priv/repo/migrations/20261021090000_retire_task_states.exs",
          __DIR__
        )

    Enum.each(apply(migration, :statements, []), &Repo.query!/1)

    # The waiting task is moved past the predecessor guard: its predecessor is open.
    assert [{"queued", %{}}, {"in_progress", %{}}, {"queued", %{}}] =
             Enum.map([first, second, third], fn task ->
               %{rows: [[state, input]]} =
                 Repo.query!("SELECT state, input FROM workflow_tasks WHERE id = $1", [
                   Ecto.UUID.dump!(task.id)
                 ])

               {state, input}
             end)

    # The guard is back.
    assert_raise Postgrex.Error, ~r/incomplete predecessors/, fn ->
      Repo.query!("UPDATE workflow_tasks SET state = 'in_progress' WHERE id = $1", [
        Ecto.UUID.dump!(third.id)
      ])
    end
  end

  defp fixture do
    suffix = System.unique_integer([:positive])
    project_key = "states-project-#{suffix}"
    roadmap_key = "states-map-#{suffix}"

    {:ok, definition} =
      Definition.parse(%{
        tasks: [
          %{id: "first", kind: :oban},
          %{id: "second", kind: :oban, depends_on: ["first"]},
          %{id: "third", kind: :oban, depends_on: ["second"]}
        ]
      })

    {:ok, project} = Ash.create(Project, %{key: project_key, name: "States project"})

    {:ok, roadmap} =
      Ash.create(Roadmap, %{project_id: project.id, key: roadmap_key, name: "States map"})

    {:ok, workflow} =
      Ash.create(Workflow, %{
        roadmap_id: roadmap.id,
        workflow_id: "retired-states",
        name: "States workflow",
        definition: definition
      })

    first = task!(workflow, "First")
    second = task!(workflow, "Second")
    third = task!(workflow, "Third")

    %{first: first, second: second, third: third}
  end

  defp task!(workflow, title) do
    {:ok, task} =
      Ash.create(Task, %{
        task_id: SpruceGoose.TaskId.generate(),
        workflow_id: workflow.id,
        task_type: :task,
        title: title,
        definition_of_done: "The migration moves it",
        runner: :oban,
        priority: 2
      })

    task
  end
end
