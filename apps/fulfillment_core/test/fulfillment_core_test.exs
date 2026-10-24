defmodule FulfillmentCoreTest do
  use ExUnit.Case, async: true

  alias FulfillmentCore, as: F

  defp event(state, id, op, extras \\ %{}),
    do: Map.merge(%{id: id, expected_version: state.version, op: op}, extras)

  defp applied(state, merchant, actor, id, op, extras \\ %{}) do
    {:ok, updated, :accepted} = F.apply(state, merchant, actor, event(state, id, op, extras))
    updated
  end

  test "restaurant handoff: transport and proof can only come from dispatch" do
    {:ok, initial} = F.new("restaurant", "req-1", "order-1", "restaurant-courier")

    assert {:error, :wrong_event_authority} =
             F.apply(
               initial,
               "restaurant",
               :commerce,
               event(initial, "wrong", :accept, %{transport_ref: "trip-1"})
             )

    accepted =
      applied(initial, "restaurant", :dispatch, "ack", :accept, %{transport_ref: "trip-1"})

    assert accepted.transport_ref == "trip-1"
    assert F.pending?(accepted)

    moving = applied(accepted, "restaurant", :dispatch, "move", :in_transit)
    delivered =
      applied(moving, "restaurant", :dispatch, "drop", :delivered, %{
        proof_ref: "custody-digest-1"
      })

    assert delivered.phase == :delivered
    assert delivered.proof_ref == "custody-digest-1"
    refute F.pending?(delivered)

    assert {:error, :terminal_fulfillment} =
             F.apply(
               delivered,
               "restaurant",
               :dispatch,
               event(delivered, "again", :delivered, %{proof_ref: "different"})
             )
  end

  test "cancel before acknowledgment remains pending until dispatch confirms" do
    {:ok, original} = F.new("merchant", "r", "o", "courier")
    state = applied(original, "merchant", :commerce, "cancel", :cancel)
    assert state.phase == :cancel_requested
    assert F.pending?(state)

    state =
      applied(state, "merchant", :dispatch, "late-ack", :accept, %{
        transport_ref: "transport-after-cancel"
      })

    assert state.phase == :cancel_requested
    assert state.transport_ref == "transport-after-cancel"
    done = applied(state, "merchant", :dispatch, "cancel-confirm", :cancel_confirmed)
    assert done.phase == :cancelled
  end

  test "nonrestaurant transport uses the same contract with separate order owner" do
    {:ok, state} = F.new("parts-supplier", "req-kit", "sale-kit", "freight")
    state =
      applied(state, "parts-supplier", :dispatch, "ack", :accept, %{transport_ref: "load-5"})

    state = applied(state, "parts-supplier", :commerce, "cancel", :cancel)
    assert state.phase == :cancel_requested

    assert {:error, :wrong_event_authority} =
             F.apply(
               state,
               "parts-supplier",
               :commerce,
               event(state, "confirm", :cancel_confirmed)
             )

    final = applied(state, "parts-supplier", :dispatch, "confirm", :cancel_confirmed)
    assert final.phase == :cancelled
    assert {:error, :wrong_merchant} =
             F.apply(final, "other-merchant", :dispatch, event(final, "oops", :in_transit))
  end

  test "duplicates replay safely; conflicting IDs and stale revisions refuse" do
    {:ok, original} = F.new("merchant", "request", "order", "courier")
    ack = event(original, "one", :accept, %{transport_ref: "transport"})
    {:ok, state, :accepted} = F.apply(original, "merchant", :dispatch, ack)
    assert {:ok, state, :duplicate} = F.apply(state, "merchant", :dispatch, ack)

    assert {:error, :idempotency_conflict} =
             F.apply(state, "merchant", :commerce, ack)

    assert {:error, :stale_fulfillment_version} =
             F.apply(state, "merchant", :dispatch, %{ack | id: "two"})

    assert {:ok, ^state} =
             F.replay(original, "merchant", [
               {:dispatch, ack},
               {:dispatch, ack}
             ])
  end

  test "cannot deliver before transport or silently cancel after acceptance" do
    {:ok, state} = F.new("merchant", "r", "o", "courier")

    assert {:error, :invalid_fulfillment_transition} =
             F.apply(
               state,
               "merchant",
               :dispatch,
               event(state, "drop", :delivered, %{proof_ref: "proof"})
             )

    state = applied(state, "merchant", :dispatch, "a", :accept, %{transport_ref: "t"})
    state = applied(state, "merchant", :commerce, "c", :cancel)
    assert state.phase == :cancel_requested

    assert {:error, :invalid_fulfillment_transition} =
             F.apply(state, "merchant", :dispatch, event(state, "move", :in_transit))
  end
end
