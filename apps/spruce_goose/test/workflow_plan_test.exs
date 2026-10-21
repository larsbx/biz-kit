defmodule SpruceGoose.WorkflowPlanTest do
  use ExUnit.Case, async: true

  alias SpruceGoose.Workflows.Lifecycle
  alias TaskCore.{TaskLifecycle, Workflow}

  test "a release blueprint plans on the host's lifecycle without conflating ledger semantics" do
    document = %{
      "schema_version" => 2,
      "project" => %{"key" => "product", "name" => "Product"},
      "roadmaps" => [
        %{
          "key" => "q4",
          "name" => "Fourth quarter",
          "workflows" => [
            %{
              "id" => "release",
              "name" => "Release",
              "tasks" => [
                %{
                  "id" => "publish",
                  "title" => "Publish",
                  "depends_on" => ["build"],
                  "definition_of_done" => [
                    %{"id" => "announcement", "description" => "Published"}
                  ]
                },
                %{
                  "id" => "build",
                  "title" => "Build",
                  "definition_of_done" => [%{"id" => "artifact", "description" => "Signed"}]
                }
              ]
            }
          ]
        }
      ]
    }

    assert {:ok, [build, publish]} =
             Workflow.plan(
               document,
               "q4",
               "release",
               %{"build" => "build-42", "publish" => "publish-42"},
               {Lifecycle, Lifecycle.version()}
             )

    assert build["state"] == "inbox"
    assert publish["predecessor_ids"] == ["build-42"]
    # The legacy writer's lifecycle is the ledger's, state for state.
    assert Lifecycle.version() == TaskLifecycle.version()
    assert Lifecycle.states() == TaskLifecycle.states()
    assert Lifecycle.transitions() == TaskLifecycle.transitions()
  end
end
