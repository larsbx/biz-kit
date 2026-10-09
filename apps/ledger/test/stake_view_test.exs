defmodule CoopSubstrate.StakeViewTest do
  @moduledoc """
  Phase 11B (docs/phase11b_plan.md): one call answers "what do I have?";
  every number agrees with the underlying module's own answer; the view
  reaches nothing beyond the subject and their own co-signed edges.
  """

  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.Capital
  alias CoopSubstrate.Dispatch
  alias CoopSubstrate.Floor
  alias CoopSubstrate.Log
  alias CoopSubstrate.Sim.Demo
  alias CoopSubstrate.StakeView
  alias CoopSubstrate.Throughput

  @chapter "chapter-genesis"
  @entity "E-carrier-1"
  @t0 1_752_000_000_000
  @week 604_800_000

  test "the sim carrier's whole stake in one call, agreeing with the demo's own numbers" do
    {:ok, r} = Demo.run("chapter-sim-stake")
    ch = r.chapter_id

    assert {:ok, stake} = StakeView.view(ch, "M-sim-carrier", at: @t0)

    assert stake.member_id == "M-sim-carrier"
    assert %{"E-sim-carrier" => entity} = stake.memberships
    assert entity.state == :member
    assert entity.class == "carriers_coop"

    # Composition, never recomputation: the dispatch section IS the demo
    # kit; capital agrees with Capital; no floor rule in the sim world is
    # reported as such, never guessed around.
    assert entity.dispatch == r.demo_kit
    assert {:ok, balance} = Capital.balance(ch, "M-sim-carrier", "E-sim-carrier")
    assert entity.capital.balance_minor == balance
    assert entity.capital.redemption_schedule == nil
    assert entity.floor.cleared == {:no_active_floor_rule, ch}
    assert entity.floor.throughput == :no_active_floor_rule

    # The netting members' rail is not the carrier's: no edges appear.
    assert stake.obligations == []
  end

  test "capital, floor, throughput, and edges agree with the modules on a plain chapter" do
    steward = new_member("steward")
    ada = new_member("member")
    bob = new_member("member")
    :ok = seed_membership!(steward, ada, "M-ada", @entity)
    {:ok, _} = Log.append(signed_event(bob, "MemberRegistered", registration_payload("M-bob", bob)))

    for {type, payload} <- [
          {"AccrualRuleActivated", %{"rule_id" => "capital-accrual-v1", "params" => %{}}},
          {"ThroughputRuleActivated",
           %{"rule_id" => "throughput-weighted-v1", "params" => %{"default_weight_bp" => 10_000}}},
          {"FloorRuleActivated",
           %{
             "rule_id" => "floor-threshold-v1",
             "params" => %{"window_ms" => @week, "default_threshold_minor" => 100}
           }},
          {"PatronageRecorded",
           %{
             "member_id" => "M-ada",
             "entity_id" => @entity,
             "kind" => "delivery",
             "amount_minor" => 5_000
           }},
          {"ThroughputRecorded",
           %{
             "member_id" => "M-ada",
             "entity_id" => @entity,
             "component" => "delivery",
             "units" => 7,
             "occurred_ms" => @t0
           }}
        ] do
      {:ok, _} = Log.append(signed_event(steward, type, payload))
    end

    as_role = fn actor, role -> %{actor | signer: %{actor.signer | role: role}} end

    {:ok, _} =
      Log.append(
        multi_signed_event(
          [as_role.(ada, "debtor"), as_role.(bob, "creditor")],
          "ObligationRecorded",
          %{
            "obligation_id" => "OB-1",
            "debtor_id" => "M-ada",
            "creditor_id" => "M-bob",
            "amount_minor" => 4_200,
            "denomination" => "USD"
          }
        )
      )

    at = @t0 + 1_000
    assert {:ok, stake} = StakeView.view(@chapter, "M-ada", at: at)
    entity = stake.memberships[@entity]

    # Agreement with each module's own answer.
    assert {:ok, entity.capital.balance_minor} == Capital.balance(@chapter, "M-ada", @entity)
    assert {:ok, entity.floor.cleared} == Floor.cleared?(@chapter, "M-ada", @entity, at: at)

    assert {:ok, entity.floor.throughput.value} ==
             Throughput.value(@chapter, "M-ada", @entity, {at - @week, at})

    assert {:ok, entity.dispatch} == Dispatch.demo_kit(@chapter, "M-ada", @entity)

    # The member's own edge, from their side.
    assert stake.obligations == [
             %{
               obligation_id: "OB-1",
               direction: :owes,
               counterparty: "M-bob",
               amount_minor: 4_200,
               denomination: "USD"
             }
           ]

    # Bob sees the same edge from HIS side — and nothing of ada's stake.
    assert {:ok, bobs} = StakeView.view(@chapter, "M-bob")
    assert [%{direction: :owed, counterparty: "M-ada"}] = bobs.obligations
    assert bobs.memberships == %{}

    # A third member reaches none of it; a stranger errors.
    carol = new_member("member")

    {:ok, _} =
      Log.append(signed_event(carol, "MemberRegistered", registration_payload("M-carol", carol)))

    assert {:ok, carols} = StakeView.view(@chapter, "M-carol")
    assert carols.obligations == []
    assert carols.memberships == %{}

    assert {:error, {:unregistered_member, "M-ghost"}} = StakeView.view(@chapter, "M-ghost")
  end
end
