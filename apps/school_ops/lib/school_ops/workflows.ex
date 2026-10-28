defmodule SchoolOps.Workflows do
  @moduledoc """
  School-specific *proposed* work, using biz-kit's shared TaskCore vocabulary.

  The first workflow prepares the Grade 2 place-value unit for teaching.
  Tasks are staff work (scope, resource, lesson, assessment and weekly-plan
  reviews), not student assignments or observations of learner mastery.

  Blueprint generation and planning are pure. No tasks are admitted here:
  the existing platform host must verify the blueprint source revision,
  authorize its use, allocate unique IDs and append through its signed ledger.
  """

  @course "C-MATH-001"
  @unit "U-MATH-001-01"

  @references %{
    "scope_review" => [@course, @unit, "A-MATH-001-01"],
    "resource_review" => [@unit, "R-KHAN-001", "R-KHAN-007"],
    "lesson_review" => [
      @unit,
      "L-MATH-001-01-01",
      "L-MATH-001-01-02",
      "L-MATH-001-01-03",
      "L-MATH-001-01-04",
      "L-MATH-001-01-05",
      "L-MATH-001-01-06"
    ],
    "assessment_review" => [@unit, "A-MATH-001-02"],
    "weekly_plan" => [@course, @unit, "A-MATH-001-02"]
  }

  @blueprint %{
    "schema_version" => 2,
    "project" => %{"key" => "school-ops", "name" => "School operations"},
    "roadmaps" => [
      %{
        "key" => "grade2",
        "name" => "Grade 2 mathematics",
        "workflows" => [
          %{
            "id" => "place_value_readiness",
            "name" => "Place-value teaching readiness",
            "tasks" => [
              %{
                "id" => "scope_review",
                "title" => "Review place-value unit scope",
                "description" =>
                  "Review C-MATH-001, U-MATH-001-01 and entry check A-MATH-001-01; " <>
                    "resolve proposed entry route, classroom materials and time budget.",
                "definition_of_done" => [
                  %{
                    "id" => "route",
                    "description" =>
                      "Review the entry-check route without presuming any learner's starting skills."
                  },
                  %{
                    "id" => "time",
                    "description" =>
                      "Record a reviewed time and calendar decision, or identify the unresolved blocker."
                  }
                ]
              },
              %{
                "id" => "resource_review",
                "title" => "Check instructional resource suitability",
                "description" =>
                  "Review U-MATH-001-01 resource references. Khan Academy practice " <>
                    "is optional and does not determine the curriculum or readiness.",
                "depends_on" => ["scope_review"],
                "definition_of_done" => [
                  %{
                    "id" => "access",
                    "description" =>
                      "Verify access, audience and taught-range suitability for any selected resources."
                  },
                  %{
                    "id" => "rights",
                    "description" =>
                      "Record source attribution and redistribution status; do not copy unlicensed content."
                  }
                ]
              },
              %{
                "id" => "lesson_review",
                "title" => "Review the six place-value lesson records",
                "description" =>
                  "Check lessons L-MATH-001-01-01 through L-MATH-001-01-06 against " <>
                    "the unit's prerequisites and course outcomes.",
                "depends_on" => ["scope_review"],
                "definition_of_done" => [
                  %{
                    "id" => "arts",
                    "description" =>
                      "Review concrete arithmetic together with grammar, reasoning and explanation in each lesson."
                  },
                  %{
                    "id" => "criteria",
                    "description" =>
                      "Check prerequisite links and observable outcome-linked lesson checks; retain draft blockers."
                  }
                ]
              },
              %{
                "id" => "assessment_review",
                "title" => "Review the place-value assessment design",
                "description" =>
                  "Review A-MATH-001-02, including PV2/PV3 and the optional PVX extension.",
                "depends_on" => ["lesson_review"],
                "definition_of_done" => [
                  %{
                    "id" => "outcomes",
                    "description" =>
                      "Check tasks, teacher keys and individual criteria for outcomes O-MATH-001-001 through 004."
                  },
                  %{
                    "id" => "range",
                    "description" =>
                      "Keep assessment form tied to the actually taught scope, not grade alone; PVX stays optional."
                  }
                ]
              },
              %{
                "id" => "weekly_plan",
                "title" => "Prepare a reviewed teaching-week plan",
                "description" =>
                  "Use school planning templates after material readiness and resource " <>
                    "availability are checked; do not publish individual learner information.",
                "depends_on" => ["assessment_review", "resource_review"],
                "definition_of_done" => [
                  %{
                    "id" => "schedule",
                    "description" =>
                      "Review session order, agreed time budget, materials and prerequisite checks."
                  },
                  %{
                    "id" => "ready",
                    "description" =>
                      "Verify referenced lesson, assessment and required resource statuses before marking the plan ready."
                  }
                ]
              }
            ]
          }
        ]
      }
    ]
  }

  @doc "Return the reviewable TaskCore schema-2 blueprint; no persistence."
  def blueprint, do: @blueprint

  @doc "Validate the same schema used by every other biz-kit task domain."
  def validate, do: TaskCore.Blueprint.normalize(blueprint())

  @doc "School-domain source IDs referenced by a named task definition."
  def references(task_id) when is_binary(task_id) do
    case Map.fetch(@references, task_id) do
      {:ok, ids} -> {:ok, ids}
      :error -> {:error, :unknown_school_task}
    end
  end

  def references(_), do: {:error, :unknown_school_task}

  @doc """
  Build the ordered task plan with TaskCore. This does not authorize, create,
  schedule, review or complete a task; the existing host admits changes.
  """
  def plan(ids),
    do:
      TaskCore.Workflow.plan(
        blueprint(),
        "grade2",
        "place_value_readiness",
        ids,
        {TaskCore.TaskLifecycle, 1}
      )
end
