defmodule SpruceGoose.CLITest do
  use ExUnit.Case, async: true

  alias SpruceGoose.CLI
  alias SpruceGoose.CLI.Command
  alias SpruceGoose.SopGate
  alias SpruceGoose.TaskId

  test "returns scoped help for every command family and rejects unknown families" do
    families =
      ~w(id project blueprint roadmap workflow task dep todo ledger outbox)

    for family <- families, help_arg <- ["help", "--help"] do
      assert {:ok, help} = CLI.run([family, help_arg])
      assert help.command == family
      assert help.usage == "sprucegoose #{family} <command> [args]"
      assert help.forms != []
    end

    assert {:ok, task_help} = CLI.run(["task", "--help"])

    refute Enum.any?(task_help.forms, &String.starts_with?(&1, "add "))

    assert "instantiate --project KEY --roadmap KEY --workflow ID --blueprint REVISION --definition KEY --priority N [--type task|diagnosis]" in task_help.forms

    assert "list [--state S] [--project KEY] [--roadmap KEY] [--workflow ID] [--type T] [--label L] [--assignee A] [--priority N] [--text T]" in task_help.forms

    assert {:error, :usage} = CLI.run(["unknown", "--help"])
    assert {:ok, root_help} = CLI.run(["--help"])
    assert root_help.usage == "sprucegoose <command> [args]"
    assert {:ok, %{version: _}} = CLI.run(["--version"])
  end

  test "generates and validates the spec task ID schema" do
    now = ~U[2026-07-27 01:23:51Z]
    id = TaskId.generate(now, <<0xEA, 0x5B, 0xA1, 0xB1>>)

    assert id == "tsk-20260727T012351Z-ea5ba1b1"
    assert TaskId.valid?(id)
    refute TaskId.valid?("tsk-20260231T012351Z-ea5ba1b1")
    refute TaskId.valid?("tsk-20260727T012351Z-EA5BA1B1")
    refute TaskId.valid?("114")
  end

  test "parses failed-event inspection and replay commands" do
    assert {:ok, :list_failed_outbox} = Command.parse(["outbox", "failed"])

    assert {:ok, {:replay_outbox, "ad6cb708-3d90-47de-a701-19a45689f7ee"}} =
             Command.parse(["outbox", "replay", "ad6cb708-3d90-47de-a701-19a45689f7ee"])

    assert {:error, :usage} = Command.parse(["outbox", "replay"])
  end

  test "unbound task add is retired from the public command surface" do
    assert {:error, message} = Command.parse(["task", "add", "Legacy task"])
    assert message =~ "retired"
    assert message =~ "task instantiate"
  end

  test "task instantiation requires an exact blueprint and definition key" do
    assert {:ok, {:instantiate_task, task}} =
             Command.parse([
               "task",
               "instantiate",
               "--project",
               "pi",
               "--roadmap",
               "delivery",
               "--workflow",
               "release-v1",
               "--blueprint",
               "bpr-abc",
               "--definition",
               "test",
               "--priority",
               "1"
             ])

    assert task.blueprint == "bpr-abc"
    assert task.definition == "test"
    assert task.priority == 1
    assert task.task_type == :task

    assert {:error, "--definition is required"} =
             Command.parse([
               "task",
               "instantiate",
               "--project",
               "pi",
               "--roadmap",
               "delivery",
               "--workflow",
               "release-v1",
               "--blueprint",
               "bpr-abc",
               "--priority",
               "1"
             ])
  end

  test "refuses legacy hierarchy admission commands" do
    for argv <- [
          ["project", "add", "dogfood", "Dogfood"],
          ["roadmap", "add", "dogfood", "dev", "Development"],
          ["workflow", "add", "--project", "dogfood", "--roadmap", "dev"]
        ] do
      assert {:error, message} = Command.parse(argv)
      assert message =~ "verified repository blueprint"
    end
  end

  test "parses hierarchy read commands with optional scope filters" do
    assert {:ok, :list_projects} = Command.parse(["project", "list"])
    assert {:ok, {:show_project, "pi"}} = Command.parse(["project", "show", "pi"])
    assert {:ok, {:view_project, "pi"}} = Command.parse(["project", "view", "pi"])

    assert {:ok, {:register_blueprint, "pi", "root/pi", "commit", ".sprucegoose/project.yaml"}} =
             Command.parse([
               "blueprint",
               "register",
               "pi",
               "root/pi",
               "commit",
               ".sprucegoose/project.yaml"
             ])

    assert {:ok, {:apply_blueprint, "pi", "root/pi", "commit", ".sprucegoose/project.yaml"}} =
             Command.parse([
               "blueprint",
               "apply",
               "pi",
               "root/pi",
               "commit",
               ".sprucegoose/project.yaml"
             ])

    assert {:ok, {:list_roadmaps, nil}} = Command.parse(["roadmap", "list"])

    assert {:ok, {:list_roadmaps, "pi"}} =
             Command.parse(["roadmap", "list", "--project", "pi"])

    assert {:ok, {:show_roadmap, "pi", "pi-platform-governance"}} =
             Command.parse(["roadmap", "show", "pi", "pi-platform-governance"])

    assert {:ok, {:list_workflows, nil, nil}} = Command.parse(["workflow", "list"])

    assert {:ok, {:list_workflows, "pi", nil}} =
             Command.parse(["workflow", "list", "--project", "pi"])

    assert {:ok, {:list_workflows, nil, "dashboard"}} =
             Command.parse(["workflow", "list", "--roadmap", "dashboard"])

    assert {:ok, {:list_workflows, "pi", "pi-platform-governance"}} =
             Command.parse([
               "workflow",
               "list",
               "--project",
               "pi",
               "--roadmap",
               "pi-platform-governance"
             ])

    assert {:ok, {:show_workflow, "pi", "pi-platform-governance", "pi-icm-doc-accuracy"}} =
             Command.parse([
               "workflow",
               "show",
               "pi",
               "pi-platform-governance",
               "pi-icm-doc-accuracy"
             ])
  end

  test "parses dependency graph query commands" do
    task_id = "tsk-20260810T142243Z-66915779"

    assert {:ok, {:task_blockers, ^task_id}} =
             Command.parse(["task", "blockers", task_id])

    assert {:ok, {:task_impact, ^task_id}} =
             Command.parse(["task", "impact", task_id])

    assert {:ok, {:workflow_critical_path, "openclaw-system", "convergence", "v1"}} =
             Command.parse([
               "workflow",
               "critical-path",
               "openclaw-system",
               "convergence",
               "v1"
             ])
  end

  test "hierarchy read commands reject stray arguments and unknown options" do
    assert {:error, :usage} = Command.parse(["project", "list", "extra"])
    assert {:error, :usage} = Command.parse(["project", "show"])
    assert {:error, :usage} = Command.parse(["roadmap", "show", "pi"])
    assert {:error, :usage} = Command.parse(["workflow", "show", "pi", "roadmap"])

    assert {:error, "invalid list arguments"} = Command.parse(["roadmap", "list", "pi"])

    assert {:error, "invalid list arguments"} =
             Command.parse(["workflow", "list", "--bogus", "x"])
  end

  test "retired task add refuses every legacy argument shape" do
    base = [
      "task",
      "add",
      "--project",
      "pi",
      "--roadmap",
      "roadmap",
      "--workflow",
      "workflow",
      "--priority",
      "3",
      "--dod",
      "done",
      "--sop",
      SopGate.path()
    ]

    for args <- [base, base ++ ["--type", "shell", "x"]] do
      assert {:error, message} = Command.parse(args)
      assert message =~ "task add is retired"
      assert message =~ "task instantiate"
    end
  end

  test "parses operator lifecycle commands" do
    id = "tsk-20260727T044500Z-1234abcd"

    assert {:ok, {:list_tasks, %{state: "queued"}}} =
             Command.parse(["task", "list", "--state", "queued"])

    assert {:ok, {:transition_task, ^id, :proposed, nil}} =
             Command.parse(["task", "propose", id])

    assert {:ok, {:transition_task, ^id, :queued, nil}} = Command.parse(["task", "queue", id])
    assert {:ok, {:transition_task, ^id, :ready, nil}} = Command.parse(["task", "ready", id])

    assert {:ok, {:transition_task, ^id, :in_progress, nil}} =
             Command.parse(["task", "start", id])

    assert {:ok, {:transition_task, ^id, :queued, "operator review"}} =
             Command.parse(["task", "reopen", id, "operator", "review"])

    assert {:error, _} = Command.parse(["task", "reopen", id])
    assert {:error, _} = Command.parse(["task", "wait", id, "operator", "review"])

    assert {:ok, {:link_task, ^id, "evidence", "/tmp/proof"}} =
             Command.parse(["task", "link", id, "evidence", "/tmp/proof"])

    assert {:ok, {:acknowledge_sop, ^id, sop_path}} =
             Command.parse(["task", "acknowledge-sop", id, SopGate.path()])

    assert sop_path == SopGate.path()

    assert {:ok, {:record_artifact_receipt, ^id, "prototype", "/tmp/prototype", "telegram:6680"}} =
             Command.parse([
               "task",
               "artifact-receipt",
               id,
               "prototype",
               "/tmp/prototype",
               "telegram:6680"
             ])

    assert {:ok, {:transition_task, ^id, :completed, nil}} = Command.parse(["task", "done", id])

    assert {:ok, {:transition_task, ^id, :cancelled, "superseded"}} =
             Command.parse(["task", "cancel", id, "superseded"])

    assert {:error, :usage} = Command.parse(["task", "cancel", id])
  end

  test "parses task metadata, and refuses the retired board, column, filter and inbox families" do
    assert {:ok, {:update_task_metadata, "task-id", ~s({"priority":2})}} =
             Command.parse(["task", "metadata", "task-id", ~s({"priority":2})])

    for retired <- [
          ["board", "list", "pi", "buzz", "integration"],
          ["column", "list", "board-id"],
          ["filter", "apply", "filter-id"],
          ["inbox", "add", "note"],
          ["task", "move", "task-id", "board-id", "column-id", "a0"]
        ],
        do: assert({:error, :usage} = Command.parse(retired))
  end

  test "parses removal and unlink commands" do
    id = "tsk-20260727T044500Z-1234abcd"

    assert {:ok, {:remove_todo, ^id, "todo-abc"}} =
             Command.parse(["todo", "remove", id, "todo-abc"])

    # --remove must win over the positional link clause.
    assert {:ok, {:unlink_task, ^id, "evidence", "/tmp/proof"}} =
             Command.parse(["task", "link", id, "--remove", "evidence", "/tmp/proof"])

    assert {:ok, {:link_task, ^id, "evidence", "/tmp/proof"}} =
             Command.parse(["task", "link", id, "evidence", "/tmp/proof"])
  end

  test "rename and removal commands reject missing names and stray arguments" do
    assert {:error, :usage} = Command.parse(["todo", "remove", "tsk-20260727T044500Z-1234abcd"])
  end

  test "parses dependency authoring commands" do
    id = "tsk-20260727T044500Z-1234abcd"
    predecessor = "tsk-20260727T044500Z-abcd1234"

    assert {:ok, {:list_dependencies, ^id}} = Command.parse(["dep", "list", id])

    assert {:ok, {:add_dependency, ^id, ^predecessor}} =
             Command.parse(["dep", "add", id, "--after", predecessor])

    assert {:ok, {:remove_dependency, ^id, ^predecessor}} =
             Command.parse(["dep", "remove", id, "--after", predecessor])
  end

  test "dependency commands fail closed on malformed arguments" do
    id = "tsk-20260727T044500Z-1234abcd"

    assert {:error, "--after is required"} = Command.parse(["dep", "add", id])
    assert {:error, "--after is required"} = Command.parse(["dep", "remove", id])

    assert {:error, "invalid dependency arguments"} =
             Command.parse(["dep", "add", id, "--after", "x", "stray"])

    assert {:error, "invalid dependency arguments"} =
             Command.parse(["dep", "add", id, "--bogus", "x"])

    assert {:error, :usage} = Command.parse(["dep", "list"])
    assert {:error, :usage} = Command.parse(["dep", "bogus", id])
  end

  test "parses subordinate TODO commands" do
    id = "tsk-20260727T044500Z-1234abcd"

    assert {:ok, {:add_todo, ^id, "Attach evidence"}} =
             Command.parse(["todo", "add", id, "Attach", "evidence"])

    assert {:ok, {:list_todos, ^id}} = Command.parse(["todo", "list", id])

    assert {:ok, {:complete_todo, ^id, "todo-abc"}} =
             Command.parse(["todo", "done", id, "todo-abc"])
  end
end
