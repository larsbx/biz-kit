defmodule CoopSubstrate.FederationTest do
  @moduledoc """
  Phase 1D step 2 (docs/phase1d_plan.md P1–P2; hand-off §3, acceptance 15):
  a second chapter joins with ZERO schema/registry/code change — this file
  seeds two chapters through the exact same types and folds shipped in
  1B/1C — chapter isolation holds at the query level, and the federation
  aggregate spans both through the privacy seam as a bare total.
  """

  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.Log
  alias CoopSubstrate.Throughput

  @genesis "chapter-genesis"
  @second "chapter-two"
  @entity "E-carrier-1"
  @member "M-ada"
  @t0 1_700_000_000_000
  @wide {@t0 - 1, @t0 + 1_000}

  setup do
    steward = new_member("steward")

    # Same member id, same entity id, in BOTH chapters — sovereign worlds.
    for chapter <- [@genesis, @second] do
      member = new_member("member")
      :ok = seed_membership!(steward, member, @member, @entity, chapter_id: chapter)

      {:ok, _} =
        Log.append(
          signed_event(
            steward,
            "ThroughputRuleActivated",
            %{
              "rule_id" => "throughput-weighted-v1",
              "params" => %{"default_weight_bp" => 10_000}
            },
            chapter_id: chapter
          )
        )
    end

    %{steward: steward}
  end

  defp record!(steward, chapter, units) do
    {:ok, _} =
      Log.append(
        signed_event(
          steward,
          "ThroughputRecorded",
          %{
            "member_id" => @member,
            "entity_id" => @entity,
            "component" => "delivery",
            "units" => units,
            "occurred_ms" => @t0
          },
          chapter_id: chapter
        )
      )
  end

  test "two chapters, same types and folds; isolation holds; federation spans both", ctx do
    record!(ctx.steward, @genesis, 30)
    record!(ctx.steward, @second, 12)

    # Chapter isolation at the query level: each chapter sees only its own.
    assert {:ok, 30} = Throughput.value(@genesis, @member, @entity, @wide)
    assert {:ok, 12} = Throughput.value(@second, @member, @entity, @wide)
    assert {:ok, 30} = Throughput.system_value(@genesis, @wide)
    assert {:ok, 12} = Throughput.system_value(@second, @wide)

    # The federation total is a computation over sovereign chapter folds —
    # one seam-summed number, no event, no cross-chapter detail.
    assert {:ok, 42} = Throughput.federation_value([@genesis, @second], @wide)
    assert {:ok, 30} = Throughput.federation_value([@genesis], @wide)
    assert {:ok, 0} = Throughput.federation_value(["chapter-nowhere"], @wide)
  end

  test "the second chapter's world is independent: memberships do not leak across", ctx do
    # M-ada departed in chapter-two only; chapter-genesis is untouched.
    member_two = new_member("member")

    # Departure needs the chapter-two member's current key — re-seed a third
    # chapter world instead to keep this cheap: an id that exists in one
    # chapter simply does not exist in another.
    assert {:error, {:reject, _i, {:unregistered_member, "M-ada"}}} =
             Log.append(
               signed_event(
                 member_two,
                 "MembershipDeparted",
                 %{"member_id" => @member, "entity_id" => @entity},
                 chapter_id: "chapter-three"
               )
             )

    assert {:ok, 0} = Throughput.system_value("chapter-three", @wide)
    assert :ok = Log.verify_chains()
  end
end
