defmodule CoopSubstrate.ThroughputTest do
  @moduledoc """
  Phase 1C step 5 (docs/phase1c_plan.md P1–P3): the throughput fold is a pure
  function of (log, in-log rule version) — replay-identical, forward-only
  across rule changes (as-of stable), half-open window edges pinned, and
  obligation-rail discharges credited as the `settlement` component to both
  parties (member-level).
  """

  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.Log
  alias CoopSubstrate.Projections.Throughput, as: Fold
  alias CoopSubstrate.Throughput

  @chapter "chapter-genesis"
  @entity "E-carrier-1"
  @member "M-ada"

  # A week in ms, and a window that contains all test event times.
  @t0 1_700_000_000_000
  @wide {@t0 - 1, @t0 + 1_000_000}

  setup do
    steward = new_member("steward")
    member = new_member("member")
    :ok = seed_membership!(steward, member, @member, @entity)

    bob = new_member("member")
    {:ok, _} = Log.append(signed_event(bob, "MemberRegistered", registration_payload("M-bob", bob)))

    %{steward: steward, member: member, bob: bob}
  end

  defp as_role(actor, role), do: %{actor | signer: %{actor.signer | role: role}}

  defp activate!(steward, params) do
    {:ok, [env]} =
      Log.append(
        signed_event(steward, "ThroughputRuleActivated", %{
          "rule_id" => "throughput-weighted-v1",
          "params" => params
        })
      )

    env.global_seq
  end

  defp record!(steward, attrs) do
    payload =
      Map.merge(
        %{
          "member_id" => @member,
          "entity_id" => @entity,
          "component" => "delivery",
          "units" => 10,
          "occurred_ms" => @t0
        },
        Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
      )

    {:ok, [env]} = Log.append(signed_event(steward, "ThroughputRecorded", payload))
    env.global_seq
  end

  defp value!(window, opts \\ []) do
    {:ok, value} = Throughput.value(@chapter, @member, @entity, window, opts)
    value
  end

  test "purity: replay twice yields the identical state", ctx do
    activate!(ctx.steward, %{"default_weight_bp" => 10_000})
    record!(ctx.steward, units: 7)

    {:ok, once} = Log.replay(Fold)
    {:ok, twice} = Log.replay(Fold)
    assert once == twice
  end

  test "weighted credit; rule change applies forward only (as-of stable)", ctx do
    activate!(ctx.steward, %{
      "default_weight_bp" => 10_000,
      "weights_bp" => %{"delivery" => 5_000}
    })

    seq_v1 = record!(ctx.steward, units: 10)
    assert value!(@wide) == 5

    # New params double everything — but only forward.
    activate!(ctx.steward, %{"default_weight_bp" => 20_000})
    record!(ctx.steward, units: 10)

    assert value!(@wide) == 5 + 20

    # The pre-activation answer is byte-stable under as-of replay.
    assert value!(@wide, as_of: seq_v1) == 5

    {:ok, full} = Throughput.entries(@chapter, @member, @entity)
    {:ok, as_of} = Throughput.entries(@chapter, @member, @entity, as_of: seq_v1)
    assert as_of == Enum.take(full, length(as_of))
    assert [%{rule_id: "throughput-weighted-v1", credited_minor: 5}, %{credited_minor: 20}] = full
  end

  test "window edges: half-open [from, to)", ctx do
    activate!(ctx.steward, %{"default_weight_bp" => 10_000})

    record!(ctx.steward, units: 1, occurred_ms: @t0)
    record!(ctx.steward, units: 2, occurred_ms: @t0 + 100)

    assert value!({@t0, @t0 + 100}) == 1
    assert value!({@t0, @t0 + 101}) == 3
    assert value!({@t0 + 1, @t0 + 101}) == 2
    assert value!({@t0 + 101, @t0 + 200}) == 0
  end

  test "discharges credit settlement to both parties — the CURRENT debtor after assignment",
       ctx do
    activate!(ctx.steward, %{
      "default_weight_bp" => 10_000,
      "weights_bp" => %{"settlement" => 100}
    })

    carol = new_member("member")

    {:ok, _} =
      Log.append(signed_event(carol, "MemberRegistered", registration_payload("M-carol", carol)))

    {:ok, _} =
      Log.append(
        multi_signed_event([as_role(ctx.member, "debtor"), as_role(ctx.bob, "creditor")],
          "ObligationRecorded",
          %{
            "obligation_id" => "OB-1",
            "debtor_id" => @member,
            "creditor_id" => "M-bob",
            "amount_minor" => 50_000,
            "denomination" => "USD"
          }
        )
      )

    {:ok, _} =
      Log.append(
        multi_signed_event([as_role(ctx.member, "assignor"), as_role(carol, "assignee")],
          "ObligationAssigned",
          %{"obligation_id" => "OB-1", "new_debtor_id" => "M-carol"}
        )
      )

    {:ok, _} =
      Log.append(
        multi_signed_event([as_role(carol, "debtor"), as_role(ctx.bob, "creditor")],
          "ObligationDischarged",
          %{"obligation_id" => "OB-1"},
          timestamp_ms: @t0 + 50
        )
      )

    # 50_000 × 100bp / 10_000 = 500, to carol and bob; nothing to Ada (the
    # original debtor was substituted out).
    {:ok, state} = Log.replay(Fold)
    assert Fold.value(state, @chapter, "M-carol", nil, @wide) == 500
    assert Fold.value(state, @chapter, "M-bob", nil, @wide) == 500
    assert Fold.value(state, @chapter, @member, @entity, @wide) == 0

    # Member-level settlement counts toward any of the member's memberships
    # (PLACEHOLDER semantics, see the fold's moduledoc).
    assert Fold.value(state, @chapter, "M-bob", "E-carrier-1", @wide) == 500

    assert [%{component: "settlement", units: 50_000, credited_minor: 500}] =
             Fold.entries(state, @chapter, "M-bob", nil)
  end

  test "a discharge before any throughput rule is active credits nothing", ctx do
    {:ok, _} =
      Log.append(
        multi_signed_event([as_role(ctx.member, "debtor"), as_role(ctx.bob, "creditor")],
          "ObligationRecorded",
          %{
            "obligation_id" => "OB-1",
            "debtor_id" => @member,
            "creditor_id" => "M-bob",
            "amount_minor" => 50_000,
            "denomination" => "USD"
          }
        )
      )

    {:ok, _} =
      Log.append(
        multi_signed_event([as_role(ctx.member, "debtor"), as_role(ctx.bob, "creditor")],
          "ObligationDischarged",
          %{"obligation_id" => "OB-1"},
          timestamp_ms: @t0
        )
      )

    {:ok, state} = Log.replay(Fold)
    assert Fold.value(state, @chapter, "M-bob", nil, @wide) == 0
    assert Fold.entries(state, @chapter, "M-bob", nil) == []
  end
end
