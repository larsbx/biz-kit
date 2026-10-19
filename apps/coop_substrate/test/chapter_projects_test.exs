defmodule CoopSubstrate.ChapterProjectsTest do
  @moduledoc """
  A chapter's projects, for its administrators
  (docs/architecture/2026-10-19-chapter-projects.md): every project with a
  task or a grant, its tasks by state, and who holds something there now.
  """
  use ExUnit.Case, async: false
  use CoopSubstrate.LogCase

  import CoopSubstrate.TaskTimingFixtures

  alias CoopSubstrate.{Administrators, Log}

  defp in_project(payload, project), do: Map.put(payload, "project_id", project)

  test "each project with a task or a grant, its tasks by state, and who holds something now" do
    gov = new_member("governance")
    laptop = new_member("operator")
    tablet = new_member("reviewer")

    {:ok, [_, grant]} =
      Log.append([declare_governance(gov), operator_grant(gov, laptop, "alice")])

    {:ok, _} =
      Log.append([
        create(laptop, grant, "task-1", unscheduled()),
        create(laptop, grant, "task-2", unscheduled())
      ])

    # Bob reviews in project-2 until he is offboarded from it; the project stays.
    reviewer = reviewer_grant(gov, tablet, "bob")

    {:ok, _} =
      Log.append(signed_event(gov, reviewer.type, in_project(reviewer.payload, "project-2")))

    assert [_, %{project_id: "project-2", people: ["bob"]}] =
             Administrators.projects("chapter-genesis")

    {:ok, _} =
      Log.append(offboard(gov, "bob", %{"tenant_id" => "tenant-1", "project_id" => "project-2"}))

    assert Administrators.projects("chapter-genesis") == [
             %{
               tenant_id: "tenant-1",
               project_id: "project-1",
               tasks: %{"inbox" => 2},
               grants: 1,
               people: ["alice"]
             },
             %{tenant_id: "tenant-1", project_id: "project-2", tasks: %{}, grants: 0, people: []}
           ]

    assert Administrators.projects("chapter-other") == []
  end
end
