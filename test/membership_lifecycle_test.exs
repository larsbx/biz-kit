defmodule CoopSubstrate.MembershipLifecycleTest do
  @moduledoc """
  Phase 1B acceptance item 10 (exhaustive state-machine transitions): the
  lifecycle table is checked over the FULL states × events matrix — every
  pair not explicitly declared legal must be rejected.
  """

  use ExUnit.Case, async: true

  alias CoopSubstrate.Membership.Lifecycle

  # The declared machine (docs/phase1b_plan.md). This test restates it
  # independently so an accidental edit to the table can't silently pass.
  @legal %{
    "MembershipInvited" => {[nil], :invited},
    "MembershipProbationStarted" => {[:invited], :probationary},
    "MembershipConfirmed" => {[:probationary], :member},
    "MembershipDeparted" => {[:invited, :probationary, :member], :departed},
    "MembershipRetired" => {[:member], :retired},
    "MembershipFloorExited" => {[:member], :floor_exited},
    "MembershipDeceased" => {[:probationary, :member], :deceased}
  }

  @all_states [nil | [:invited, :probationary, :member, :departed, :retired, :floor_exited, :deceased]]

  test "the declared event set is exactly the lifecycle event set" do
    assert Enum.sort(Map.keys(@legal)) == Enum.sort(Lifecycle.event_types())
  end

  test "the declared state set is exhaustive" do
    assert Enum.sort(Lifecycle.states()) ==
             Enum.sort([:invited, :probationary, :member, :departed, :retired, :floor_exited, :deceased])
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
             Enum.sort([:departed, :retired, :floor_exited, :deceased])

    # No lifecycle event leaves a terminal state (the matrix test proves it;
    # this states the intent directly).
    for state <- [:departed, :retired, :floor_exited, :deceased],
        event <- Lifecycle.event_types() do
      assert {:error, _} = Lifecycle.apply(state, event)
    end
  end

  test "active-for-patronage states are probationary and member (PLACEHOLDER semantics)" do
    for state <- @all_states do
      assert Lifecycle.active?(state) == (state in [:probationary, :member])
    end
  end
end
