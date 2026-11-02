defmodule SpruceGoose.Web.ProjectOwnershipTest do
  @moduledoc "Signed chapter-scoped HTTP contracts for ownerless project backfill."
  use ExUnit.Case, async: false

  import SpruceGoose.LedgerFixtures

  alias CoopSubstrate.Governance.Client
  alias CoopSubstrate.Log
  alias TaskCore.Projects

  setup do
    w = world()
    Map.put(w, :base, serve!())
  end

  defp backfill_url(w, project, principal) do
    w.base <>
      "/api/v1/chapters/#{w.chapter}/tenants/#{tenant()}/projects/#{project}" <>
      "/ownership/backfill/#{Client.segment(principal)}"
  end

  test "only chapter governance may discover ownerless projects", w do
    grant!(w, "TaskOperatorGrantedV1", member("operator"), "legacy", "old-project")

    url = w.base <> "/api/v1/chapters/#{w.chapter}/ownerless_projects"
    assert {:error, {401, _}} = Client.get(url)

    assert {:ok, projects} = Client.get_signed(url, governance(w))
    assert [%{"project_id" => "old-project", "owner" => nil}] = projects

    other = world()
    assert {:error, {401, _}} = Client.get_signed(url, governance(other))
  end

  test "governance signs one atomic backfill batch for an eligible human", w do
    grant!(w, "TaskOperatorGrantedV1", member("operator"), "legacy", "old-project")

    operator = member("operator")
    url = backfill_url(w, "old-project", "bob")
    params = %{
      "operator_device" => %{
        "key_id" => operator.signer.key_id,
        "pubkey" => Base.url_encode64(operator.signer.pubkey, padding: false)
      }
    }

    assert {:ok, %{"events" => events}} =
             Client.sign_batch(
               url,
               governance(w),
               fn cores ->
                 Enum.map(cores, & &1["type"]) == [
                   "TaskPrincipalKindDeclaredV1",
                   "TaskOperatorGrantedV1",
                   "TaskProjectOwnerAssignedV1"
                 ] and
                   Enum.all?(cores, fn core ->
                     core["chapter_id"] == w.chapter and
                       core["signers"] == [
                         %{
                           "role" => "governance",
                           "key_id" => w.gov.signer.key_id,
                           "pubkey" => {:bytes, w.gov.signer.pubkey}
                         }
                       ]
                   end)
               end,
               params
             )

    assert length(events) == 3
    o = Log.gate().orchestration
    scope = {w.chapter, tenant(), "old-project"}
    assert Projects.owner(o, scope) == "bob"
    assert Projects.eligible_owner?(o, scope)

    url = w.base <> "/api/v1/chapters/#{w.chapter}/ownerless_projects"
    assert {:ok, []} = Client.get_signed(url, governance(w))
  end

  test "chapter offboarding signs both project-successor assignments in one batch", w do
    append!(
      event(w, w.gov, "TaskPrincipalKindDeclaredV1", %{
        "principal_id" => "alice",
        "kind" => "human"
      })
    )

    url = w.base <> "/api/v1/principals/owner/chapter_offboarding"
    selections = [
      %{"tenant_id" => tenant(), "project_id" => "project-1", "principal_id" => "alice"},
      %{"tenant_id" => tenant(), "project_id" => "project-2", "principal_id" => "alice"}
    ]

    assert {:error, {409, _}} =
             Client.sign_batch(
               url,
               governance(w),
               fn _ -> true end,
               %{"chapter_id" => w.chapter}
             )

    assert {:ok, %{"events" => events}} =
             Client.sign_batch(
               url,
               governance(w),
               fn cores ->
                 Enum.map(cores, & &1["type"]) == [
                   "TaskPrincipalOffboardedV1",
                   "TaskPrincipalOffboardedV1",
                   "TaskProjectOwnerAssignedV1",
                   "TaskProjectOwnerAssignedV1"
                 ]
               end,
               %{"chapter_id" => w.chapter, "successors" => selections}
             )

    assert length(events) == 4
    o = Log.gate().orchestration

    for project <- ["project-1", "project-2"] do
      scope = {w.chapter, tenant(), project}
      assert Projects.owner(o, scope) == "alice"
      assert Projects.eligible_owner?(o, scope)
    end

    assert Projects.violations(o) == []
  end

  test "duplicate successor selections fail before any signature", w do
    append!(
      event(w, w.gov, "TaskPrincipalKindDeclaredV1", %{
        "principal_id" => "alice",
        "kind" => "human"
      })
    )

    url = w.base <> "/api/v1/principals/owner/chapter_offboarding"
    selected = %{"tenant_id" => tenant(), "project_id" => "project-1", "principal_id" => "alice"}

    assert {:error, {400, _}} =
             Client.sign_batch(
               url,
               governance(w),
               fn _ -> true end,
               %{"chapter_id" => w.chapter, "successors" => [selected, selected]}
             )
  end

  test "backfill cannot cross a tenant or create a phantom legacy project", w do
    grant!(w, "TaskOperatorGrantedV1", member("operator"), "legacy", "old-project")
    operator = member("operator")
    params = %{
      "operator_device" => %{
        "key_id" => operator.signer.key_id,
        "pubkey" => Base.url_encode64(operator.signer.pubkey, padding: false)
      }
    }

    foreign = w.base <>
      "/api/v1/chapters/#{w.chapter}/tenants/tenant-9/projects/old-project" <>
      "/ownership/backfill/bob"

    assert {:error, {409, _}} =
             Client.sign_batch(foreign, governance(w), fn _ -> true end, params)

    missing = backfill_url(w, "missing-project", "bob")

    assert {:error, {409, _}} =
             Client.sign_batch(missing, governance(w), fn _ -> true end, params)

    assert Projects.owner(Log.gate().orchestration, {w.chapter, tenant(), "old-project"}) ==
             nil
  end
end
