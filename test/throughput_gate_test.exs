defmodule CoopSubstrate.ThroughputGateTest do
  @moduledoc """
  Phase 1C step 4 over the real log: gate checks for throughput recording,
  rule activations (params validated against the code registries), and floor
  evaluations (active-rule match; hardship suspends the floor). All
  rejections happen before persistence with chains intact.
  """

  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.Log

  @chapter "chapter-genesis"
  @entity "E-carrier-1"
  @member "M-ada"

  setup do
    ctx = %{steward: new_member("steward"), member: new_member("member")}
    :ok = seed_membership!(ctx.steward, ctx.member, @member, @entity)
    ctx
  end

  defp throughput(attrs \\ []) do
    Map.merge(
      %{
        "member_id" => @member,
        "entity_id" => @entity,
        "component" => "delivery",
        "units" => 3,
        "occurred_ms" => 1_700_000_000_000
      },
      Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
    )
  end

  defp activate_throughput!(steward, params \\ %{"default_weight_bp" => 10_000}) do
    {:ok, _} =
      Log.append(
        signed_event(steward, "ThroughputRuleActivated", %{
          "rule_id" => "throughput-weighted-v1",
          "params" => params
        })
      )
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

  defp evaluation(attrs \\ []) do
    Map.merge(
      %{
        "member_id" => @member,
        "entity_id" => @entity,
        "cleared" => true,
        "rule_id" => "floor-threshold-v1",
        "window_ms" => 604_800_000,
        "value" => 12_000
      },
      Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
    )
  end

  defp assert_rejected(envelope, expected_reason) do
    before_head = Log.head()
    assert {:error, {:reject, _i, reason}} = Log.append(envelope)
    assert reason == expected_reason
    assert Log.head() == before_head
    assert :ok = Log.verify_chains()
  end

  test "recording requires an active rule; then components in the closed set land", ctx do
    assert_rejected(
      signed_event(ctx.steward, "ThroughputRecorded", throughput()),
      {:no_active_throughput_rule, @chapter}
    )

    activate_throughput!(ctx.steward)

    {:ok, _} = Log.append(signed_event(ctx.steward, "ThroughputRecorded", throughput()))

    assert_rejected(
      signed_event(ctx.steward, "ThroughputRecorded", throughput(component: "settlement")),
      {:unknown_component, "settlement"}
    )

    assert_rejected(
      signed_event(ctx.steward, "ThroughputRecorded", throughput(units: 0)),
      :units_must_be_positive
    )

    assert_rejected(
      signed_event(ctx.steward, "ThroughputRecorded", throughput(occurred_ms: 0)),
      :bad_occurred_ms
    )
  end

  test "recording requires an active membership", ctx do
    activate_throughput!(ctx.steward)

    assert_rejected(
      signed_event(ctx.steward, "ThroughputRecorded", throughput(member_id: "M-ghost")),
      {:no_membership, "M-ghost", @entity}
    )

    {:ok, _} =
      Log.append(
        signed_event(ctx.member, "MembershipDeparted", %{
          "member_id" => @member,
          "entity_id" => @entity
        })
      )

    assert_rejected(
      signed_event(ctx.steward, "ThroughputRecorded", throughput()),
      {:membership_not_active, :departed}
    )
  end

  test "rule activations are validated against the code registries", ctx do
    assert_rejected(
      signed_event(ctx.steward, "ThroughputRuleActivated", %{
        "rule_id" => "throughput-vibes-v9",
        "params" => %{}
      }),
      :unknown_rule
    )

    assert_rejected(
      signed_event(ctx.steward, "ThroughputRuleActivated", %{
        "rule_id" => "throughput-weighted-v1",
        "params" => %{"weights_bp" => %{"delivery" => 10_000}}
      }),
      # default_weight_bp is REQUIRED in the activation — declared constants,
      # no code fallback (00 Art. IV.2).
      :bad_default_weight
    )

    assert_rejected(
      signed_event(ctx.steward, "FloorRuleActivated", %{
        "rule_id" => "floor-threshold-v1",
        "params" => %{"window_ms" => 0, "default_threshold_minor" => 100}
      }),
      :bad_window
    )
  end

  test "floor evaluations bind to the active floor rule", ctx do
    assert_rejected(
      signed_event(ctx.steward, "FloorEvaluationRecorded", evaluation()),
      {:no_active_floor_rule, @chapter}
    )

    activate_floor!(ctx.steward, %{"window_ms" => 604_800_000, "default_threshold_minor" => 100})

    {:ok, _} = Log.append(signed_event(ctx.steward, "FloorEvaluationRecorded", evaluation()))

    assert_rejected(
      signed_event(
        ctx.steward,
        "FloorEvaluationRecorded",
        evaluation(rule_id: "floor-threshold-v0")
      ),
      {:not_the_active_floor_rule, "floor-threshold-v0"}
    )

    assert_rejected(
      signed_event(ctx.steward, "FloorEvaluationRecorded", evaluation(window_ms: 0)),
      :bad_window
    )
  end

  test "hardship suspends floor evaluation", ctx do
    activate_floor!(ctx.steward, %{"window_ms" => 604_800_000, "default_threshold_minor" => 100})

    {:ok, _} =
      Log.append(
        signed_event(ctx.member, "HardshipDeclared", %{
          "member_id" => @member,
          "entity_id" => @entity
        })
      )

    assert_rejected(
      signed_event(ctx.steward, "FloorEvaluationRecorded", evaluation()),
      :floor_suspended_by_hardship
    )

    {:ok, _} =
      Log.append(
        signed_event(ctx.member, "HardshipEnded", %{
          "member_id" => @member,
          "entity_id" => @entity
        })
      )

    {:ok, _} = Log.append(signed_event(ctx.steward, "FloorEvaluationRecorded", evaluation()))
  end
end
