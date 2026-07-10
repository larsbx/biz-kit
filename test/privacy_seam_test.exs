defmodule CoopSubstrate.PrivacySeamTest do
  @moduledoc """
  Phase 1C step 8 (docs/phase1c_plan.md P8; hand-off acceptance item 13):
  aggregate queries route through `Privacy.Aggregate`, and swapping the
  backing changes ZERO caller code — the literal same assertion function
  runs under both backings. Plus the Proof seam's first two facts under the
  trusted-but-auditable backing: prove pins a log position, verify IS the
  recomputation.
  """

  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.Capital
  alias CoopSubstrate.Log
  alias CoopSubstrate.Privacy
  alias CoopSubstrate.Throughput

  @chapter "chapter-genesis"
  @entity "E-carrier-1"
  @member "M-ada"
  @t0 1_700_000_000_000
  @wide {@t0 - 1, @t0 + 1_000}

  defmodule OpaqueBacking do
    @moduledoc "Test-only swap target: same totals, different (marked) path."

    @behaviour CoopSubstrate.Privacy.Aggregate

    @impl true
    def sum(contributions) do
      send(self(), {:aggregate_backing, __MODULE__})
      Enum.reduce(contributions, 0, &+/2)
    end
  end

  setup do
    steward = new_member("steward")
    member = new_member("member")
    :ok = seed_membership!(steward, member, @member, @entity)

    {:ok, _} =
      Log.append(
        signed_event(steward, "ThroughputRuleActivated", %{
          "rule_id" => "throughput-weighted-v1",
          "params" => %{"default_weight_bp" => 10_000}
        })
      )

    for units <- [30, 12] do
      {:ok, _} =
        Log.append(
          signed_event(steward, "ThroughputRecorded", %{
            "member_id" => @member,
            "entity_id" => @entity,
            "component" => "delivery",
            "units" => units,
            "occurred_ms" => @t0
          })
        )
    end

    for {entity, amount} <- [{@entity, 700}, {"E-mech-1", 300}] do
      if entity != @entity do
        {:ok, _} =
          Log.append(
            signed_event(steward, "EntityRegistered", %{
              "entity_id" => entity,
              "class" => "mechanics_coop"
            })
          )
      end

      {:ok, _} =
        Log.append(
          signed_event(steward, "SinkingFundContributed", %{
            "entity_id" => entity,
            "amount_minor" => amount
          })
        )
    end

    %{steward: steward, member: member}
  end

  # THE seam-swap assertions: called verbatim under both backings.
  defp assert_aggregates do
    assert {:ok, 42} = Throughput.system_value(@chapter, @wide)
    assert {:ok, 1_000} = Capital.sinking_fund_total(@chapter)
  end

  test "aggregates through the seam; swapping the backing changes zero caller code" do
    # Default (plaintext) backing.
    assert_aggregates()
    refute_received {:aggregate_backing, _}

    # Swap the backing by config alone — no caller changes.
    Application.put_env(:coop_substrate, :aggregate_backing, OpaqueBacking)
    on_exit(fn -> Application.delete_env(:coop_substrate, :aggregate_backing) end)

    assert_aggregates()
    assert_received {:aggregate_backing, OpaqueBacking}
  end

  test "Proof seam: floor_cleared — prove pins a log position, verify recomputes", ctx do
    {:ok, _} =
      Log.append(
        signed_event(ctx.steward, "FloorRuleActivated", %{
          "rule_id" => "floor-threshold-v1",
          "params" => %{"window_ms" => 1_000, "default_threshold_minor" => 40}
        })
      )

    fact = {:floor_cleared, @chapter, @member, @entity, @t0 + 1}

    assert {:ok, proof} = Privacy.Proof.prove(fact)
    assert Privacy.Proof.verify(fact, proof)

    # A proof binds to ITS fact: another member's fact fails verification.
    other = {:floor_cleared, @chapter, "M-eve", @entity, @t0 + 1}
    refute Privacy.Proof.verify(other, proof)

    # A fact that does not hold yields no proof (value 42 < threshold 100).
    {:ok, _} =
      Log.append(
        signed_event(ctx.steward, "FloorRuleActivated", %{
          "rule_id" => "floor-threshold-v1",
          "params" => %{"window_ms" => 1_000, "default_threshold_minor" => 100}
        })
      )

    assert {:error, :fact_does_not_hold} = Privacy.Proof.prove(fact)

    # The OLD proof still verifies: it pinned the log position where the
    # 40-threshold rule was active — auditable, not revisionist.
    assert Privacy.Proof.verify(fact, proof)
  end

  test "Proof seam: balance_at_least", ctx do
    {:ok, _} =
      Log.append(
        signed_event(ctx.steward, "AccrualRuleActivated", %{
          "rule_id" => "capital-accrual-v1",
          "params" => %{}
        })
      )

    {:ok, _} =
      Log.append(
        signed_event(ctx.steward, "PatronageRecorded", %{
          "member_id" => @member,
          "entity_id" => @entity,
          "kind" => "linehaul",
          "amount_minor" => 5_000
        })
      )

    assert {:ok, proof} = Privacy.Proof.prove({:balance_at_least, @chapter, @member, @entity, 5_000})
    assert Privacy.Proof.verify({:balance_at_least, @chapter, @member, @entity, 5_000}, proof)

    assert {:error, :fact_does_not_hold} =
             Privacy.Proof.prove({:balance_at_least, @chapter, @member, @entity, 5_001})
  end
end
