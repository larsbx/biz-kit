defmodule SchoolOps.DomainTest do
  use ExUnit.Case, async: true

  alias SchoolOps.{Catalog, Workflows}

  @task_ids %{
    "scope_review" => "scope-42",
    "resource_review" => "resources-42",
    "lesson_review" => "lessons-42",
    "assessment_review" => "assessment-42",
    "weekly_plan" => "weekly-42"
  }

  test "the course, unit, lessons, assessments and resources resolve by stable ID" do
    assert length(Catalog.ids()) == 17

    for id <- Catalog.ids() do
      assert {:ok, %{id: ^id, kind: kind, path: path, body: body}} = Catalog.fetch(id)
      assert kind in [:course, :unit, :lesson, :assessment, :resource]
      assert String.ends_with?(path, ".md")
      assert String.contains?(body, id)
    end

    assert {:ok, %{body: unit}} = Catalog.fetch("U-MATH-001-01")
    assert unit =~ "Status: draft"
    assert {:error, :unknown_curriculum_record} = Catalog.fetch("C-MATH-999")
    assert {:error, :unknown_curriculum_record} = Catalog.fetch("../README.md")
    assert {:error, :unknown_curriculum_record} = Catalog.fetch(nil)
  end

  test "the SchoolOps proposal uses the common validated TaskCore blueprint" do
    assert {:ok, normalized} = Workflows.validate()
    assert normalized["schema_version"] == TaskCore.Blueprint.schema_version()

    assert {:ok, workflow} =
             TaskCore.Blueprint.workflow(normalized, "grade2", "place_value_readiness")

    assert length(workflow["tasks"]) == 5

    assert Enum.all?(workflow["tasks"], fn task ->
             {:ok, ids} = Workflows.references(task["id"])
             Enum.all?(ids, &match?({:ok, _}, Catalog.fetch(&1)))
           end)

    assert {:error, :unknown_school_task} = Workflows.references("unknown")
    assert {:error, :unknown_school_task} = Workflows.references(nil)
  end

  test "the shared engine orders and links school work without storing anything" do
    assert {:ok, plan} = Workflows.plan(@task_ids)

    assert Enum.map(plan, & &1["id"]) == [
             "scope_review",
             "lesson_review",
             "assessment_review",
             "resource_review",
             "weekly_plan"
           ]

    assert Enum.all?(plan, &(&1["state"] == "inbox"))
    assert Enum.all?(plan, &(&1["lifecycle_version"] == 1))

    assert Enum.find(plan, &(&1["id"] == "weekly_plan"))["predecessor_ids"] ==
             ["assessment-42", "resources-42"]

    assert Enum.find(plan, &(&1["id"] == "lesson_review"))["predecessor_ids"] ==
             ["scope-42"]
  end

  test "invalid or incomplete instance IDs are refused by TaskCore" do
    assert {:error, :invalid_workflow_run} = Workflows.plan(%{})

    assert {:error, :invalid_workflow_run} =
             Workflows.plan(Map.put(@task_ids, "weekly_plan", "scope-42"))

    assert {:error, :invalid_workflow_run} =
             Workflows.plan(Map.put(@task_ids, "weekly_plan", "../invalid"))
  end

  test "completing task planning cannot assert lesson readiness or mastery" do
    assert {:ok, plan} = Workflows.plan(@task_ids)
    assert Enum.all?(plan, &(&1["state"] == "inbox"))

    assert {:ok, %{body: material}} = Catalog.fetch("A-MATH-001-02")
    assert material =~ "Status: draft"
    refute Enum.any?(plan, &Map.has_key?(&1, "learner_id"))
    refute Enum.any?(plan, &Map.has_key?(&1, "score"))
  end
end
