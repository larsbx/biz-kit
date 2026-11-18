defmodule DispatchCore.AdmissionTest do
  use ExUnit.Case, async: true

  alias DispatchCore.Admission

  @ch "ch"
  @gov %{role: "governance", key_id: "k-gov", pubkey: <<1::256>>}
  @disp %{role: "dispatch_dispatcher", key_id: "k-disp", pubkey: <<2::256>>}

  defp env(type, signer, payload),
    do: %{type: type, chapter_id: @ch, signers: [signer], payload: payload}

  defp gate(dispatch),
    do: %{role_keys: %{{@ch, "governance"} => %{"k-gov" => <<1::256>>}}, dispatch: dispatch}

  defp grant(tenant \\ "t1"),
    do:
      env("DispatchDispatcherGrantedV1", @gov, %{
        "tenant_id" => tenant,
        "dispatcher_id" => "d1",
        "key_id" => "k-disp",
        "pubkey" => {:bytes, <<2::256>>}
      })

  defp plan(id, holds, tenant \\ "t1"),
    do:
      env(
        "DispatchAssignmentPlannedV1",
        @disp,
        Map.merge(%{"tenant_id" => tenant, "assignment_id" => id, "load_id" => "L-" <> id}, holds)
      )

  defp move(id, action, version, tenant \\ "t1"),
    do:
      env("DispatchAssignmentTransitionV1", @disp, %{
        "tenant_id" => tenant,
        "assignment_id" => id,
        "expected_version" => version,
        "action" => action
      })

  # Admit each event in order, as the single appender does; return the state
  # and every refusal.
  defp run(events) do
    Enum.reduce(events, {Admission.init(), []}, fn e, {state, refused} ->
      case Admission.check(e, gate(state)) do
        :ok -> {Admission.fold(e, gate(state)), refused}
        {:error, reason} -> {state, refused ++ [reason]}
      end
    end)
  end

  test "only declared governance grants a dispatcher, once per key" do
    rogue = %{@gov | key_id: "k-rogue"}

    {_, refused} =
      run([env("DispatchDispatcherGrantedV1", rogue, grant().payload), grant(), grant()])

    assert refused == [:dispatch_governance_not_declared, :dispatcher_key_already_granted]
  end

  test "only a dispatcher granted for the tenant, with its key, plans or moves" do
    other = %{@disp | pubkey: <<3::256>>}
    p = plan("a1", %{"operator_id" => "o1"})

    {_, refused} =
      run([
        plan("a0", %{"operator_id" => "o1"}),
        grant(),
        %{p | signers: [other]},
        plan("a2", %{"operator_id" => "o1"}, "t2")
      ])

    assert refused == [:forbidden, :forbidden, :forbidden]
  end

  test "an operator, vehicle or trailer is on at most one ACTIVE assignment" do
    {state, refused} =
      run([
        grant(),
        plan("a1", %{"operator_id" => "o1", "vehicle_id" => "v1", "trailer_id" => "r1"}),
        plan("a2", %{"operator_id" => "o2", "vehicle_id" => "v1"}),
        plan("a3", %{"operator_id" => "o3", "trailer_id" => "r1"}),
        plan("a4", %{"operator_id" => "o1"}),
        move("a1", "activate", 0),
        move("a2", "activate", 0),
        move("a3", "activate", 0),
        move("a4", "activate", 0)
      ])

    assert refused == [
             {:already_active, :vehicle, "v1", "a1"},
             {:already_active, :trailer, "r1", "a1"},
             {:already_active, :operator, "o1", "a1"}
           ]

    assert Admission.active(state, @ch, "t1", :vehicle, "v1") == "a1"
    assert Admission.assignments(state, @ch, "t1")["a2"].status == :PLANNED
  end

  test "completing or cancelling an ACTIVE assignment frees what it held" do
    holds = %{"operator_id" => "o1", "vehicle_id" => "v1"}

    {state, refused} =
      run([
        grant(),
        plan("a1", holds),
        plan("a2", holds),
        plan("a3", holds),
        move("a1", "activate", 0),
        move("a1", "complete", 1),
        move("a2", "activate", 0),
        move("a2", "cancel", 1),
        move("a3", "activate", 0)
      ])

    assert refused == []
    assert Admission.active(state, @ch, "t1", :operator, "o1") == "a3"

    assert Admission.assignments(state, @ch, "t1")["a1"] |> Map.take([:status, :version]) ==
             %{status: :COMPLETED, version: 2}
  end

  test "versions, legal moves and identities are checked" do
    {_, refused} =
      run([
        grant(),
        plan("a1", %{"operator_id" => "o1"}),
        plan("a1", %{"operator_id" => "o2"}),
        move("a1", "complete", 0),
        move("a1", "activate", 1),
        move("a1", "teleport", 0),
        move("a9", "activate", 0),
        move("a1", "cancel", 0),
        move("a1", "activate", 1)
      ])

    assert refused == [
             :assignment_exists,
             {:illegal_transition, :PLANNED, "complete"},
             :stale_version,
             :unknown_action,
             :unknown_assignment,
             {:illegal_transition, :CANCELLED, "activate"}
           ]
  end

  test "tenants are independent" do
    {state, refused} =
      run([
        grant("t1"),
        grant("t2") |> put_in([:payload, "key_id"], "k-disp-2"),
        plan("a1", %{"operator_id" => "o1"}),
        move("a1", "activate", 0)
      ])

    assert refused == []
    assert Admission.active(state, @ch, "t2", :operator, "o1") == nil
  end
end
