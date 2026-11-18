defmodule CoopSubstrate.DispatchAssignmentsTest do
  @moduledoc """
  Dispatch assignments on the common append path (DispatchCore.Admission):
  admitted by the single appender against the advancing fold, and rebuilt
  from the ledger alone.
  """
  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.Log

  @tenant "tenant-1"

  setup do
    gov = new_member("governance")
    dispatcher = new_member("dispatch_dispatcher")

    {:ok, _} =
      Log.append(
        signed_event(gov, "RoleKeyDeclared", %{
          "role" => "governance",
          "key_id" => gov.signer.key_id,
          "pubkey" => {:bytes, gov.signer.pubkey}
        })
      )

    {:ok, _} =
      Log.append(
        signed_event(gov, "DispatchDispatcherGrantedV1", %{
          "tenant_id" => @tenant,
          "dispatcher_id" => "dispatcher-1",
          "key_id" => dispatcher.signer.key_id,
          "pubkey" => {:bytes, dispatcher.signer.pubkey}
        })
      )

    %{gov: gov, dispatcher: dispatcher}
  end

  defp plan(d, id, holds),
    do:
      signed_event(
        d,
        "DispatchAssignmentPlannedV1",
        Map.merge(
          %{"tenant_id" => @tenant, "assignment_id" => id, "load_id" => "L-" <> id},
          holds
        )
      )

  defp move(d, id, action, version),
    do:
      signed_event(d, "DispatchAssignmentTransitionV1", %{
        "tenant_id" => @tenant,
        "assignment_id" => id,
        "expected_version" => version,
        "action" => action
      })

  defp assignments,
    do: DispatchCore.Admission.assignments(Log.gate().dispatch, "chapter-genesis", @tenant)

  test "concurrent activations sharing a vehicle admit exactly one", %{dispatcher: d} do
    ids = for i <- 1..8, do: "a#{i}"

    for {id, i} <- Enum.with_index(ids),
        do: {:ok, _} = Log.append(plan(d, id, %{"operator_id" => "o#{i}", "vehicle_id" => "v1"}))

    results =
      ids
      |> Enum.map(fn id -> Task.async(fn -> Log.append(move(d, id, "activate", 0)) end) end)
      |> Enum.map(&Task.await/1)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1

    assert Enum.count(
             results,
             &match?({:error, {:reject, 0, {:already_active, :vehicle, "v1", _}}}, &1)
           ) ==
             7

    assert assignments() |> Map.values() |> Enum.count(&(&1.status == :ACTIVE)) == 1
  end

  test "an ungranted or other-tenant signer appends nothing", %{dispatcher: d} do
    head = Log.head()
    stranger = new_member("dispatch_dispatcher")

    assert {:error, {:reject, 0, :forbidden}} =
             Log.append(plan(stranger, "a1", %{"operator_id" => "o1"}))

    other =
      signed_event(d, "DispatchAssignmentPlannedV1", %{
        "tenant_id" => "tenant-2",
        "assignment_id" => "a1",
        "load_id" => "L",
        "operator_id" => "o1"
      })

    assert {:error, {:reject, 0, :forbidden}} = Log.append(other)
    assert Log.head() == head
  end

  test "the assignment view is rebuilt from the ledger alone", %{dispatcher: d} do
    {:ok, _} = Log.append(plan(d, "a1", %{"operator_id" => "o1", "trailer_id" => "r1"}))
    {:ok, _} = Log.append(plan(d, "a2", %{"operator_id" => "o2", "trailer_id" => "r1"}))
    {:ok, _} = Log.append(move(d, "a1", "activate", 0))
    {:ok, _} = Log.append(move(d, "a1", "complete", 1))
    {:ok, _} = Log.append(move(d, "a2", "activate", 0))
    before = Log.gate().dispatch

    restart_log()

    assert Log.gate().dispatch == before

    assert %{"a1" => %{status: :COMPLETED}, "a2" => %{status: :ACTIVE, version: 1}} =
             assignments()

    assert {:error, {:reject, 0, :stale_version}} = Log.append(move(d, "a2", "complete", 0))
  end
end
