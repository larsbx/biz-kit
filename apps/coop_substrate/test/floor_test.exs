defmodule CoopSubstrate.FloorTest do
  @moduledoc """
  Phase 1C step 6 (docs/phase1c_plan.md P1–P3): `Floor.cleared?/4` is a pure,
  windowed, versioned predicate over the log — per-class thresholds from the
  active rule's params, rolling window ages work out, hardship suspends
  evaluation, and `as_of:` reproduces any historical verdict.
  """

  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.Floor
  alias CoopSubstrate.Log

  @chapter "chapter-genesis"
  @entity "E-carrier-1"
  @member "M-ada"
  @t0 1_700_000_000_000

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

    %{steward: steward, member: member}
  end

  defp activate_floor!(steward, params) do
    {:ok, _} =
      Log.append(
        signed_event(steward, "FloorRuleActivated", %{
          "rule_id" => "floor-threshold-v1",
          "params" => params
        })
      )
  end

  defp record!(steward, units, occurred_ms) do
    {:ok, [env]} =
      Log.append(
        signed_event(steward, "ThroughputRecorded", %{
          "member_id" => @member,
          "entity_id" => @entity,
          "component" => "delivery",
          "units" => units,
          "occurred_ms" => occurred_ms
        })
      )

    env.global_seq
  end

  test "per-class threshold; the rolling window ages work out", ctx do
    activate_floor!(ctx.steward, %{
      "window_ms" => 1_000,
      "default_threshold_minor" => 100,
      "thresholds_minor" => %{"carriers_coop" => 50}
    })

    record!(ctx.steward, 50, @t0)

    # 50 ≥ 50 under the carriers_coop override (the default 100 would fail).
    assert {:ok, true} = Floor.cleared?(@chapter, @member, @entity, at: @t0 + 1)

    # One window later the work has aged out of [at − 1000, at).
    assert {:ok, false} = Floor.cleared?(@chapter, @member, @entity, at: @t0 + 1_001)
  end

  test "as_of reproduces the historical verdict", ctx do
    activate_floor!(ctx.steward, %{"window_ms" => 1_000, "default_threshold_minor" => 100})

    seq_before = record!(ctx.steward, 40, @t0)
    record!(ctx.steward, 60, @t0 + 1)

    assert {:ok, true} = Floor.cleared?(@chapter, @member, @entity, at: @t0 + 2)

    assert {:ok, false} =
             Floor.cleared?(@chapter, @member, @entity, at: @t0 + 2, as_of: seq_before)
  end

  test "hardship suspends evaluation; ending it restores the verdict", ctx do
    activate_floor!(ctx.steward, %{"window_ms" => 1_000, "default_threshold_minor" => 100})
    record!(ctx.steward, 100, @t0)

    membership = %{"member_id" => @member, "entity_id" => @entity}
    {:ok, _} = Log.append(signed_event(ctx.member, "HardshipDeclared", membership))

    assert {:error, :floor_suspended_by_hardship} =
             Floor.cleared?(@chapter, @member, @entity, at: @t0 + 1)

    {:ok, _} = Log.append(signed_event(ctx.member, "HardshipEnded", membership))

    assert {:ok, true} = Floor.cleared?(@chapter, @member, @entity, at: @t0 + 1)
  end

  test "distinct non-verdict states: no membership, no active floor rule", ctx do
    assert {:error, {:no_active_floor_rule, @chapter}} =
             Floor.cleared?(@chapter, @member, @entity, at: @t0)

    activate_floor!(ctx.steward, %{"window_ms" => 1_000, "default_threshold_minor" => 100})

    assert {:error, {:no_membership, "M-ghost", @entity}} =
             Floor.cleared?(@chapter, "M-ghost", @entity, at: @t0)
  end
end
