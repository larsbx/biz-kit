defmodule TaskHost.Web.PredecessorMigrationTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import TaskHost.LedgerFixtures

  alias CoopSubstrate.{Log, PredecessorChanges}
  alias CoopSubstrate.Governance.Client

  setup do
    w = world()
    governance_keys!(w)
    scope = {w.chapter, tenant(), "project-1"}

    for id <- ["first", "second"] do
      create!(w, w.op_grant, id)

      append!(
        event(w, w.op, "TaskProposedV1", %{
          "tenant_id" => tenant(),
          "project_id" => "project-1",
          "task_id" => id,
          "principal_id" => "alice",
          "authorization_event_id" => w.op_grant.event_id,
          "lifecycle_version" => 1,
          "expected_version" => 1
        })
      )

      append!(
        event(w, w.gov, "TaskReadinessDefinedV1", %{
          "tenant_id" => tenant(),
          "project_id" => "project-1",
          "task_id" => id,
          "expected_version" => 2,
          "predecessor_ids" => [],
          "artifact_requirements" => %{"input" => {:bytes, <<123::256>>}},
          "sop_digest" => {:bytes, <<7::256>>},
          "sop_version" => "2.0.0"
        })
      )
    end

    create!(w, w.op_grant_2, "other", "project-2")
    Map.merge(w, %{base: serve!(), scope: scope})
  end

  defp change(w, operation, id, predecessor) do
    capture_io(fn ->
      scope = w.scope |> Tuple.to_list() |> Enum.join("/")

      Mix.Tasks.Coop.Task.Predecessor.run([
        operation,
        scope,
        id,
        predecessor,
        "--server",
        w.base,
        "--yes"
      ])
    end)
  end

  defp task(%{scope: {chapter, tenant, project}}, id),
    do: Log.gate().orchestration.tasks[{chapter, tenant, project, id}]

  test "add and remove sign the exact reviewed list and preserve custody commitments", w do
    old = task(w, "second").readiness
    assert change(w, "add", "second", "first") =~ "changed: event"
    current = task(w, "second").readiness
    assert current.predecessor_ids == ["first"]

    assert Map.take(current, [:artifact_requirements, :sop_digest, :sop_version]) ==
             Map.take(old, [:artifact_requirements, :sop_digest, :sop_version])

    assert current.acknowledgment == nil

    before = Log.head()
    assert_raise Mix.Error, ~r/predecessor_exists/, fn -> change(w, "add", "second", "first") end
    assert_raise Mix.Error, ~r/predecessor_cycle/, fn -> change(w, "add", "first", "second") end
    assert_raise Mix.Error, ~r/unknown_predecessor/, fn -> change(w, "add", "second", "other") end
    assert Log.head() == before

    assert change(w, "remove", "second", "first") =~ "changed: event"
    assert task(w, "second").readiness.predecessor_ids == []
  end

  test "unsigned and stale requests cannot append", w do
    path =
      "/api/v1/chapters/#{w.chapter}/tenants/#{tenant()}/projects/project-1/tasks/second/predecessors"

    url = w.base <> path
    assert call(:get, path, []).status == 401
    assert {:ok, snapshot} = Client.get_signed(url, governance(w))
    assert {:ok, expected} = PredecessorChanges.replacement(snapshot, "add", "first")
    change(w, "add", "second", "first")
    before = Log.head()

    params = %{
      "expected_version" => snapshot["expected_version"],
      "predecessor_id" => "first",
      "operation" => "add"
    }

    assert {:error, {409, response}} =
             Client.sign_held(
               url,
               governance(w),
               &PredecessorChanges.expected?(&1, w.chapter, expected),
               params
             )

    assert Jason.decode!(response)["error"] == "stale_task_version"
    assert Log.head() == before
  end
end
