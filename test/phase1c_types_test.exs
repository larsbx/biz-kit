defmodule CoopSubstrate.Phase1cTypesTest do
  @moduledoc """
  Phase 1C step 3 (docs/phase1c_plan.md): the throughput/floor and
  obligation-rail event types are registered with the declared shapes —
  payload validation, stream derivation, disclosure classes. Log-dependent
  gate checks are step 4; this is pure registry surface.
  """

  use ExUnit.Case, async: true

  alias CoopSubstrate.Constants
  alias CoopSubstrate.Protocol.TypeRegistry

  @new_types ~w(
    FloorCureStarted FloorCureCleared HardshipDeclared HardshipEnded
    ThroughputRecorded ThroughputRuleActivated FloorRuleActivated
    FloorEvaluationRecorded
    ObligationRecorded ObligationAssigned ObligationDischarged
  )

  test "all Phase 1C types are registered" do
    for type <- @new_types, do: assert(TypeRegistry.registered?(type), type)
  end

  test "throughput components exclude settlement (derives from the rail, 05 §1.2)" do
    assert "settlement" not in Constants.throughput_components()
    assert Constants.throughput_components() != []
  end

  test "obligation-rail types are bilateral and dual-signed; money is unrepresentable" do
    for type <- ~w(ObligationRecorded ObligationAssigned ObligationDischarged) do
      {:ok, spec} = TypeRegistry.spec(type)
      assert spec.disclosure_class == :bilateral
      assert length(spec.required_roles) == 2, "#{type} must be dual-signed"
    end

    # 05 P11: no event type represents platform fund movement.
    for type <- TypeRegistry.types() do
      refute type =~ ~r/Payment|Transfer|Custody.*Fund|Settled/,
             "#{type} looks like a fund-movement type"
    end
  end

  test "all rail events ride the obligation's own stream" do
    for type <- ~w(ObligationRecorded ObligationAssigned ObligationDischarged) do
      assert {:ok, "chapter-genesis/obligations/OB-1"} =
               TypeRegistry.stream_id(type, "chapter-genesis", %{"obligation_id" => "OB-1"})
    end
  end

  test "throughput and floor-evaluation events are telemetry-classed, per-(member, entity)" do
    for {type, prefix} <- [{"ThroughputRecorded", "throughput"}, {"FloorEvaluationRecorded", "floor"}] do
      {:ok, spec} = TypeRegistry.spec(type)
      assert spec.disclosure_class == :telemetry

      assert {:ok, "chapter-genesis/#{prefix}/M-ada/E-carrier-1"} ==
               TypeRegistry.stream_id(type, "chapter-genesis", %{
                 "member_id" => "M-ada",
                 "entity_id" => "E-carrier-1"
               })
    end
  end

  test "payload validation rejects malformed Phase 1C events" do
    ok_throughput = %{
      "member_id" => "M-ada",
      "entity_id" => "E-carrier-1",
      "component" => "delivery",
      "units" => 3,
      "occurred_ms" => 1_700_000_000_000
    }

    assert :ok = TypeRegistry.validate_payload("ThroughputRecorded", ok_throughput)

    assert {:error, {:payload_invalid, {:missing_fields, ["units"]}}} =
             TypeRegistry.validate_payload("ThroughputRecorded", Map.delete(ok_throughput, "units"))

    assert {:error, {:payload_invalid, {:bad_field, "units"}}} =
             TypeRegistry.validate_payload(
               "ThroughputRecorded",
               %{ok_throughput | "units" => "three"}
             )

    assert {:error, {:payload_invalid, {:unknown_fields, ["counterparty_id"]}}} =
             TypeRegistry.validate_payload(
               "ThroughputRecorded",
               # Counterparty identity is sovereign edge data (07 §5) —
               # deliberately not a field on the claim event.
               Map.put(ok_throughput, "counterparty_id", "M-eve")
             )

    assert {:error, {:payload_invalid, {:bad_field, "cleared"}}} =
             TypeRegistry.validate_payload("FloorEvaluationRecorded", %{
               "evaluation_id" => "EV-1",
               "member_id" => "M-ada",
               "entity_id" => "E-carrier-1",
               "cleared" => "yes",
               "rule_id" => "floor-threshold-v1",
               "window_ms" => 1_000,
               "at_ms" => 1_700_000_000_000,
               "value" => 5
             })

    assert {:error, {:payload_invalid, {:missing_fields, ["denomination"]}}} =
             TypeRegistry.validate_payload("ObligationRecorded", %{
               "obligation_id" => "OB-1",
               "debtor_id" => "M-ada",
               "creditor_id" => "M-eve",
               "amount_minor" => 100
             })
  end
end
