defmodule CoopSubstrate.MembershipLifecycleTest do
  @moduledoc """
  Phase 1B acceptance item 10 (exhaustive state-machine transitions): the
  lifecycle table is checked over the FULL states × events matrix — every
  pair not explicitly declared legal must be rejected.
  """

  use ExUnit.Case, async: true

  alias CoopSubstrate.Membership.Lifecycle

  # The declared machine (docs/phase1b_plan.md + the 1C floor/cure/hardship
  # extension, docs/phase1c_plan.md). This test restates it independently so
  # an accidental edit to the table can't silently pass.
  @legal %{
    "MembershipInvited" => {[nil], :invited},
    "MembershipProbationStarted" => {[:invited], :probationary},
    "MembershipConfirmed" => {[:probationary], :member},
    "MembershipDeparted" =>
      {[:invited, :probationary, :member, :in_cure, :hardship], :departed},
    "MembershipRetired" => {[:member], :retired},
    "MembershipFloorExited" => {[:member, :in_cure], :floor_exited},
    "MembershipDeceased" => {[:probationary, :member, :in_cure, :hardship], :deceased},
    "FloorCureStarted" => {[:member], :in_cure},
    "FloorCureCleared" => {[:in_cure], :member},
    "HardshipDeclared" => {[:member], :hardship},
    "HardshipEnded" => {[:hardship], :member}
  }

  @non_terminal [:invited, :probationary, :member, :in_cure, :hardship]
  @terminal [:departed, :retired, :floor_exited, :deceased]
  @all_states [nil | @non_terminal ++ @terminal]

  test "the declared event set is exactly the lifecycle event set" do
    assert Enum.sort(Map.keys(@legal)) == Enum.sort(Lifecycle.event_types())
  end

  test "the declared state set is exhaustive" do
    assert Enum.sort(Lifecycle.states()) == Enum.sort(@non_terminal ++ @terminal)
  end

  test "every (state, event) pair behaves exactly per the table — exhaustive matrix" do
    for state <- @all_states, {event, {froms, to}} <- @legal do
      case Lifecycle.apply(state, event) do
        {:ok, next} ->
          assert state in froms,
                 "#{inspect(state)} --#{event}--> accepted but not declared legal"

          assert next == to

        {:error, {:illegal_transition, ^event, ^state}} ->
          refute state in froms,
                 "#{inspect(state)} --#{event}--> rejected but declared legal"
      end
    end
  end

  test "unknown event types are rejected from every state" do
    for state <- @all_states do
      assert {:error, {:not_a_lifecycle_event, "PatronageRecorded"}} =
               Lifecycle.apply(state, "PatronageRecorded")
    end
  end

  test "terminal states are exactly the redeemable-account states" do
    assert Enum.sort(Enum.filter(Lifecycle.states(), &Lifecycle.terminal?/1)) ==
             Enum.sort(@terminal)

    # No lifecycle event leaves a terminal state (the matrix test proves it;
    # this states the intent directly).
    for state <- @terminal, event <- Lifecycle.event_types() do
      assert {:error, _} = Lifecycle.apply(state, event)
    end
  end

  test "active-for-accrual states include in_cure and hardship (PLACEHOLDER semantics)" do
    for state <- @all_states do
      assert Lifecycle.active?(state) ==
               (state in [:probationary, :member, :in_cure, :hardship])
    end
  end

  test "hardship suspends floor evaluation; cure does not" do
    for state <- @all_states do
      assert Lifecycle.floor_suspended?(state) == (state == :hardship)
    end
  end
end
