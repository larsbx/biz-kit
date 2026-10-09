defmodule CoopSubstrate.ExportTest do
  @moduledoc """
  Phase 6B (docs/phase6b_plan.md): a member's departure bundle contains
  their own streams plus the chapter rule streams, verifies offline, and
  reproduces their balance — and never carries another member's streams.
  """

  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.Capital
  alias CoopSubstrate.Export
  alias CoopSubstrate.Log

  @chapter "chapter-genesis"
  @entity "E-carrier-1"
  @t0 1_700_000_000_000

  setup do
    steward = new_member("steward")
    ada = new_member("member")
    bob = new_member("member")
    :ok = seed_membership!(steward, ada, "M-ada", @entity)
    :ok = seed_membership!(steward, bob, "M-bob", @entity, register_entity: false)

    {:ok, _} =
      Log.append(
        signed_event(steward, "AccrualRuleActivated", %{
          "rule_id" => "capital-accrual-v1",
          "params" => %{}
        })
      )

    {:ok, _} =
      Log.append(
        signed_event(steward, "ThroughputRuleActivated", %{
          "rule_id" => "throughput-weighted-v1",
          "params" => %{"default_weight_bp" => 10_000}
        })
      )

    for {member_id, amount} <- [{"M-ada", 5_000}, {"M-bob", 3_000}] do
      {:ok, _} =
        Log.append(
          signed_event(steward, "PatronageRecorded", %{
            "member_id" => member_id,
            "entity_id" => @entity,
            "kind" => "linehaul",
            "amount_minor" => amount
          })
        )
    end

    {:ok, _} =
      Log.append(
        signed_event(steward, "ThroughputRecorded", %{
          "member_id" => "M-ada",
          "entity_id" => @entity,
          "component" => "delivery",
          "units" => 7,
          "occurred_ms" => @t0
        })
      )

    :ok
  end

  test "the bundle carries the member's streams plus rule streams; verifies offline; reproduces the balance" do
    assert {:ok, bundle} = Export.member_bundle(@chapter, "M-ada")

    for stream <- [
          "#{@chapter}/members/M-ada",
          "#{@chapter}/memberships/M-ada/#{@entity}",
          "#{@chapter}/patronage/M-ada/#{@entity}",
          "#{@chapter}/throughput/M-ada/#{@entity}",
          "#{@chapter}/accrual_rules",
          "#{@chapter}/throughput_rules"
        ] do
      assert Map.has_key?(bundle.streams, stream), "missing #{stream}"
    end

    # Never-activated rule streams are omitted, not shipped empty.
    refute Map.has_key?(bundle.streams, "#{@chapter}/floor_rules")

    # Offline: every stream passes strict decode + signatures + chain.
    assert {:ok, verified} = Export.verify(bundle)

    # Reproducibility (§14 discipline over the bundle): the accrual fold on
    # the verified export equals the live projection's answer.
    merged =
      (verified["#{@chapter}/accrual_rules"] ++
         verified["#{@chapter}/patronage/M-ada/#{@entity}"])
      |> Enum.sort_by(& &1.global_seq)

    {_params, bundle_balance} =
      Enum.reduce(merged, {nil, 0}, fn env, {params, sum} ->
        case env.type do
          "AccrualRuleActivated" ->
            {env.payload["params"], sum}

          "PatronageRecorded" ->
            weights = Map.get(params, "weights_bp", %{})
            default = Map.get(params, "default_weight_bp", 10_000)
            bp = Map.get(weights, env.payload["kind"], default)
            {params, sum + div(env.payload["amount_minor"] * bp, 10_000)}
        end
      end)

    assert {:ok, live_balance} = Capital.balance(@chapter, "M-ada", @entity)
    assert bundle_balance == live_balance
  end

  test "another member's streams never appear in the bundle" do
    assert {:ok, bundle} = Export.member_bundle(@chapter, "M-ada")

    refute Enum.any?(Map.keys(bundle.streams), &String.contains?(&1, "M-bob"))

    # And symmetric: Bob's bundle exists, holds his patronage, none of Ada's.
    assert {:ok, bobs} = Export.member_bundle(@chapter, "M-bob")
    assert Map.has_key?(bobs.streams, "#{@chapter}/patronage/M-bob/#{@entity}")
    refute Enum.any?(Map.keys(bobs.streams), &String.contains?(&1, "M-ada"))
  end

  test "a tampered record fails offline verification" do
    assert {:ok, bundle} = Export.member_bundle(@chapter, "M-ada")

    stream = "#{@chapter}/patronage/M-ada/#{@entity}"
    [record | rest] = bundle.streams[stream]
    <<first, tail::binary>> = record
    tampered = %{bundle | streams: Map.put(bundle.streams, stream, [<<first + 1, tail::binary>> | rest])}

    assert {:error, {:stream_invalid, ^stream, _reason}} = Export.verify(tampered)
    assert {:error, :not_a_bundle} = Export.verify(%{})
  end
end
