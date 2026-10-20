defmodule SpruceGoose.Web.RunReadinessTest do
  @moduledoc """
  Readiness for a workflow run over HTTP (docs/architecture/2026-10-20-run-readiness.md):
  a governance key asks for the run's definitions, checks each is exactly
  what it asked for, signs them all and submits them together.
  """
  use ExUnit.Case, async: false

  import SpruceGoose.LedgerFixtures

  alias CoopSubstrate.Governance.Client
  alias CoopSubstrate.Log

  setup do
    w = world()
    revision = apply_blueprint!(w)

    [run] =
      append!(
        event(w, w.op, "TaskWorkflowInstantiatedV1", %{
          "tenant_id" => tenant(),
          "project_id" => "project-1",
          "principal_id" => "alice",
          "authorization_event_id" => w.op_grant.event_id,
          "lifecycle_version" => 1,
          "revision_event_id" => revision.event_id,
          "roadmap_key" => "q4",
          "workflow_id" => "release",
          "task_ids" => %{"build" => "r1-build", "ship" => "r1-ship"}
        })
      )

    for id <- ~w(r1-build r1-ship) do
      append!(
        event(w, w.op, "TaskProposedV1", %{
          "tenant_id" => tenant(),
          "project_id" => "project-1",
          "task_id" => id,
          "principal_id" => "alice",
          "authorization_event_id" => w.op_grant.event_id,
          "expected_version" => 1,
          "lifecycle_version" => 1
        })
      )
    end

    path =
      "/api/v1/chapters/#{w.chapter}/tenants/#{tenant()}/projects/project-1/runs/#{run.event_id}/readiness"

    Map.merge(w, %{base: serve!(), path: path})
  end

  @sop String.duplicate("a", 64)

  defp task(w, id), do: Log.gate().orchestration.tasks[{w.chapter, tenant(), "project-1", id}]

  test "a governance key defines the run's readiness, signing exactly what it asked for", w do
    expected = fn cores ->
      Enum.map(cores, &{&1["type"], &1["payload"]["task_id"], &1["payload"]["predecessor_ids"]}) ==
        [
          {"TaskReadinessDefinedV1", "r1-build", []},
          {"TaskReadinessDefinedV1", "r1-ship", ["r1-build"]}
        ]
    end

    assert {:ok, %{"events" => [_, _]}} =
             Client.sign_batch(w.base <> w.path, governance(w), expected, %{
               "sop_digest" => @sop,
               "inputs" => %{}
             })

    assert task(w, "r1-ship").readiness.predecessor_ids == ["r1-build"]

    assert task(w, "r1-build").readiness.sop_digest ==
             {:bytes, Base.decode16!(@sop, case: :lower)}
  end

  test "a run may name its SOP's version; a malformed one is refused", w do
    sign = fn params ->
      Client.sign_batch(w.base <> w.path, governance(w), fn _ -> true end, params)
    end

    base = %{"sop_digest" => @sop, "inputs" => %{}}
    assert {:error, {400, _}} = sign.(Map.put(base, "sop_version", 3))
    assert {:error, {409, body}} = sign.(Map.put(base, "sop_version", "1.0"))
    assert body =~ "invalid_sop_version"
    assert {:ok, _} = sign.(Map.put(base, "sop_version", "1.2.0"))
    assert task(w, "r1-ship").readiness.sop_version == "1.2.0"
  end

  test "an unsigned request, a malformed digest and a defined run are refused", w do
    unsigned = call(:post, w.path, [{"content-type", "application/json"}], "{}")
    assert unsigned.status == 401

    sign = fn params ->
      Client.sign_batch(w.base <> w.path, governance(w), fn _ -> true end, params)
    end

    assert {:error, {400, _}} = sign.(%{"sop_digest" => "not hex", "inputs" => %{}})
    assert {:ok, _} = sign.(%{"sop_digest" => @sop, "inputs" => %{}})
    assert {:error, {409, body}} = sign.(%{"sop_digest" => @sop, "inputs" => %{}})
    assert body =~ "nothing_to_define"
  end
end
