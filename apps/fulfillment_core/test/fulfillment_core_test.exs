defmodule FulfillmentCoreTest do
  use ExUnit.Case, async: true

  alias FulfillmentCore, as: F

  defp event(state, id, op, extras \\ %{}),
    do: Map.merge(%{id: id, expected_version: state.version, op: op}, extras)

  defp applied(state, merchant, actor, id, op, extras \\ %{}) do
    {:ok, updated, :accepted} = F.apply(state, merchant, actor, event(state, id, op, extras))
    updated
  end

  test "confirmed cancellation preserves transport facts and refuses later observations" do
    {:ok, initial} = F.new("merchant", "request", "order", "courier")
    ack = event(initial, "ack", :accept, %{transport_ref: "trip"})
    {:ok, accepted, :accepted} = F.apply(initial, "merchant", :dispatch, ack)
    moving = applied(accepted, "merchant", :dispatch, "move", :in_transit)
    cancelling = applied(moving, "merchant", :commerce, "cancel", :cancel)
    cancelled = applied(cancelling, "merchant", :dispatch, "confirm", :cancel_confirmed)
    assert cancelled.transport_started
    assert cancelled.transport_ref == "trip"
    assert cancelled.proof_ref == nil
    refute F.pending?(cancelled)
    assert {:ok, ^cancelled, :duplicate} = F.apply(cancelled, "merchant", :dispatch, ack)

    for {op, extras} <- [
          {:accept, %{transport_ref: "other"}},
          {:reject, %{reason: "late"}},
          {:in_transit, %{}},
          {:delivered, %{proof_ref: "late-proof"}},
          {:failed, %{reason: "late"}},
          {:cancel_confirmed, %{}}
        ] do
      assert {:error, :terminal_fulfillment} =
               F.apply(cancelled, "merchant", :dispatch, event(cancelled, "late", op, extras))
    end
  end

  test "proof after transit then cancellation delivers without deciding a refund" do
    {:ok, initial} = F.new("merchant", "request", "order", "courier")
    accepted = applied(initial, "merchant", :dispatch, "ack", :accept, %{transport_ref: "trip"})
    moving = applied(accepted, "merchant", :dispatch, "move", :in_transit)
    cancelling = applied(moving, "merchant", :commerce, "cancel", :cancel)

    assert {:error, :invalid_reference} =
             F.apply(
               cancelling,
               "merchant",
               :dispatch,
               event(cancelling, "bad-proof", :delivered, %{proof_ref: ""})
             )

    delivered =
      applied(cancelling, "merchant", :dispatch, "proof", :delivered, %{
        proof_ref: "custody-reference"
      })

    assert delivered.phase == :delivered
    assert delivered.transport_ref == "trip"
    assert delivered.proof_ref == "custody-reference"
    refute Map.has_key?(delivered, :refund)
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

    assert {:error, :idempotency_conflict} = F.apply(state, "merchant", :commerce, ack)

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

    # A signed carrier observation can arrive after cancellation was requested
    # but before it was confirmed. It is not a cancellation confirmation.
    observed = applied(state, "merchant", :dispatch, "move", :in_transit)
    assert observed.phase == :cancel_requested
    assert observed.transport_started

    delivered =
      applied(observed, "merchant", :dispatch, "proof", :delivered, %{proof_ref: "receipt"})

    assert delivered.phase == :delivered
    assert delivered.proof_ref == "receipt"

    assert {:error, :terminal_fulfillment} =
             F.apply(
               delivered,
               "merchant",
               :dispatch,
               event(delivered, "stop", :cancel_confirmed)
             )
  end

  test "late transport rejection resolves cancellation before carrier acceptance" do
    {:ok, original} = F.new("restaurant", "req-1", "order-1", "courier")
    cancelling = applied(original, "restaurant", :commerce, "cancel", :cancel)

    assert {:error, :transport_not_accepted} =
             F.apply(cancelling, "restaurant", :dispatch, event(cancelling, "early", :in_transit))

    rejected =
      applied(cancelling, "restaurant", :dispatch, "reject", :reject, %{reason: "no_route"})

    assert rejected.phase == :rejected
    refute F.pending?(rejected)

    assert {:error, :terminal_fulfillment} =
             F.apply(
               rejected,
               "restaurant",
               :dispatch,
               event(rejected, "late", :accept, %{transport_ref: "trip-1"})
             )
  end

  test "cancellation after acceptance cannot replace transport identity or invent proof" do
    {:ok, original} = F.new("restaurant", "request", "order", "courier")

    accepted =
      applied(original, "restaurant", :dispatch, "a1", :accept, %{transport_ref: "trip-1"})

    cancelling = applied(accepted, "restaurant", :commerce, "cancel", :cancel)

    assert {:error, :transport_already_accepted} =
             F.apply(
               cancelling,
               "restaurant",
               :dispatch,
               event(cancelling, "a2", :accept, %{transport_ref: "trip-2"})
             )

    assert {:error, :delivery_without_transport_start} =
             F.apply(
               cancelling,
               "restaurant",
               :dispatch,
               event(cancelling, "proof", :delivered, %{proof_ref: "fake-proof"})
             )

    failed =
      applied(cancelling, "restaurant", :dispatch, "failed", :failed, %{
        reason: "vehicle_unavailable"
      })

    assert failed.phase == :failed
    assert failed.transport_ref == "trip-1"
  end
end
