defmodule TaskCore.WorkflowTest do
  use ExUnit.Case, async: true
  alias TaskCore.{Blueprint, TaskLifecycle, Workflow}
  alias TaskCore.Blueprint.Source

  # A second host relation with the same numeric version. It deliberately has
  # different states and transitions, as SpruceGoose does.
  defmodule OtherLifecycle do
    use TaskCore.Lifecycle,
      version: 1,
      initial: :waiting,
      transitions: [
        waiting: [:working],
        working: [:failed, :finished],
        failed: [:waiting],
        finished: []
      ]
  end

  defp doc do
    {document, _} = Code.eval_file(Path.join(__DIR__, "fixtures/curriculum.exs"))
    document
  end

  @ids %{"intro" => "lesson-1", "adding" => "lesson-2"}

  test "a deterministic plan resolves local dependencies without changing signed order" do
    document = doc()

    assert {:ok, [intro, adding] = plan} =
             Workflow.plan(document, "autumn", "fractions", @ids, {TaskLifecycle, 1})

    assert intro["task_id"] == "lesson-1"
    assert intro["state"] == "inbox"
    assert adding["predecessor_ids"] == ["lesson-1"]
    assert adding["lifecycle_version"] == 1

    reversed =
      update_in(
        document,
        ["roadmaps", Access.at(0), "workflows", Access.at(0), "tasks"],
        &Enum.reverse/1
      )

    assert {:ok, ^plan} = Workflow.plan(reversed, "autumn", "fractions", @ids, {TaskLifecycle, 1})
    assert {:ok, normalized} = Blueprint.normalize(document)

    assert {:ok, %{"tasks" => [%{"id" => "adding"}, %{"id" => "intro"}]}} =
             Blueprint.workflow(normalized, "autumn", "fractions")
  end

  test "the host chooses a full lifecycle, not a globally interpreted version number" do
    assert {:ok, [first | _]} =
             Workflow.plan(doc(), "autumn", "fractions", @ids, {OtherLifecycle, 1})

    assert first["state"] == "waiting"

    for contract <- [{TaskLifecycle, 2}, {UnknownLifecycle, 1}, {TaskLifecycle, 0}, 1] do
      assert {:error, :unsupported_task_lifecycle} =
               Workflow.plan(doc(), "autumn", "fractions", @ids, contract)
    end
  end

  test "invalid runs and definitions fail before a plan is returned" do
    for ids <- [
          nil,
          %{},
          %{"intro" => "same", "adding" => "same"},
          Map.put(@ids, "extra", "extra"),
          Map.put(@ids, "intro", "bad/id")
        ] do
      assert {:error, :invalid_workflow_run} =
               Workflow.plan(doc(), "autumn", "fractions", ids, {TaskLifecycle, 1})
    end

    assert {:error, :unknown_workflow} =
             Workflow.plan(doc(), "none", "none", @ids, {TaskLifecycle, 1})

    assert {:error, _} = Workflow.plan(%{}, "autumn", "fractions", @ids, {TaskLifecycle, 1})

    cyclic =
      update_in(
        doc(),
        ["roadmaps", Access.at(0), "workflows", Access.at(0), "tasks", Access.at(1)],
        &Map.put(&1, "depends_on", ["adding"])
      )

    assert {:error, "workflow fractions: dependency graph must be acyclic"} =
             Workflow.plan(cyclic, "autumn", "fractions", @ids, {TaskLifecycle, 1})
  end

  test "Git source identity is immutable, format-consistent and path-bounded" do
    source = %{
      "repository" => "acme/workflows",
      "commit" => String.duplicate("a", 40),
      "tree" => String.duplicate("b", 40),
      "path" => "plans/release.exs",
      "manifest_digest" => {:bytes, <<0::256>>}
    }

    assert {:ok, ^source} = Source.normalize(source)

    for {key, value} <- [
          {"commit", "main"},
          {"commit", String.duplicate("a", 64)},
          {"tree", "tag-v1"},
          {"tree", String.duplicate("c", 64)},
          {"repository", "https://github.com/acme/workflows"},
          {"manifest_digest", {:bytes, <<0>>}}
        ] do
      assert {:error, :invalid_blueprint_source} = Source.normalize(Map.put(source, key, value))
    end

    for path <- [
          "/absolute",
          "../outside",
          "plans/../file",
          "plans//file",
          "./file",
          "plans/",
          ""
        ] do
      assert {:error, :invalid_blueprint_source} =
               Source.normalize(Map.put(source, "path", path))
    end
  end
end
