defmodule DispatchCoreTest do
  use ExUnit.Case, async: true

  alias DispatchCore.{LastMile, LegacyDelivery}

  defp event(state, id, op, data \\ %{}) do
    Map.merge(%{id: id, op: op, expected_version: state.version}, data)
  end

  defp advance(state, merchant, producer, id, op, data \\ %{}) do
    {:ok, next, :accepted} = LastMile.apply(state, merchant, producer, event(state, id, op, data))
    next
  end

  test "legacy Eatsbot delivery table matches all 13 permitted edges" do
    assert length(LegacyDelivery.edges()) == 13

    assert LegacyDelivery.valid?("Init", "In_Preparation")
    assert LegacyDelivery.valid?("In_Preparation", "Ready_To_Pickup")
    assert LegacyDelivery.valid?("Ready_To_Pickup", "In_Delivery")
    assert LegacyDelivery.valid?("In_Delivery", "Delivery_Done")
    assert LegacyDelivery.valid?("Delivery_With_Problems", "In_Delivery")
    assert LegacyDelivery.valid?("Delivery_Done", "Stale_Delivery_Done")
    refute LegacyDelivery.valid?("Ready_To_Pickup", "Delivery_Done")
    refute LegacyDelivery.valid?("Delivery_With_Problems", "Delivery_Done")

    assert LegacyDelivery.next_states("Ready_To_Pickup") ==
             ["In_Delivery", "Delivery_Aborted"]

    assert {:ok, "Delivery_Done"} =
             LegacyDelivery.replay("Init", [
               {"Init", "In_Preparation"},
               {"In_Preparation", "Ready_To_Pickup"},
               {"Ready_To_Pickup", "In_Delivery"},
               {"In_Delivery", "Delivery_Done"}
             ])

    assert {:error, {:discontinuous, 0}} =
             LegacyDelivery.replay("Init", [{"Ready_To_Pickup", "In_Delivery"}])
  end

  test "restaurant and repair service last-mile policies share source-owned proof guards" do
    for merchant <- ["restaurant", "truck-repair"] do
      {:ok, initial} = LastMile.new(merchant, "delivery-1")

      assert {:error, :invalid_transition_or_authority} =
               LastMile.apply(
                 initial,
                 merchant,
                 :commerce,
                 event(initial, "forged", :picked_up, %{pickup_ref: "fake"})
               )

      ready = advance(initial, merchant, :commerce, "ready", :ready)
      moving = advance(ready, merchant, :dispatch, "pickup", :picked_up, %{pickup_ref: "signed-pickup"})
      assert moving.pickup_ref == "signed-pickup"
      assert LastMile.pending?(moving)

      assert {:error, :invalid_transition_or_authority} =
               LastMile.apply(moving, merchant, :commerce, event(moving, "fake", :delivered, %{delivery_proof_ref: "p"}))

      delivered =
        advance(moving, merchant, :dispatch, "drop", :delivered, %{
          delivery_proof_ref: "proof-digest"
        })

      assert delivered.phase == :delivered
      assert delivered.delivery_proof_ref == "proof-digest"
      refute LastMile.pending?(delivered)
    end
  end

  test "cancellation after pickup preserves late proof and cannot fabricate abort" do
    {:ok, original} = LastMile.new("merchant", "r")
    ready = advance(original, "merchant", :commerce, "ready", :ready)
    moving = advance(ready, "merchant", :dispatch, "pickup", :picked_up, %{pickup_ref: "p"})
    requested = advance(moving, "merchant", :commerce, "cancel", :cancel)
    assert requested.phase == :in_transit
    assert requested.cancel_requested?

    assert {:error, :requires_transport_resolution} =
             LastMile.apply(requested, "merchant", :dispatch, event(requested, "confirm", :cancel_confirmed))

    observed = advance(requested, "merchant", :observer, "uncertain", :uncertain)
    assert observed.held?
    assert observed.phase == :in_transit

    delivered = advance(observed, "merchant", :dispatch, "late-proof", :delivered, %{delivery_proof_ref: "signed"})
    assert delivered.phase == :delivered
    assert delivered.held?
    assert delivered.cancel_requested?
  end

  test "pre-pickup cancellation requires independent dispatch confirmation" do
    {:ok, initial} = LastMile.new("merchant", "r")
    requested = advance(initial, "merchant", :commerce, "c", :cancel)
    assert requested.phase == :awaiting_ready
    assert requested.cancel_requested?
    final = advance(requested, "merchant", :dispatch, "ack", :cancel_confirmed)
    assert final.phase == :cancelled

    assert {:error, :terminal_delivery} =
             LastMile.apply(final, "merchant", :dispatch, event(final, "late", :picked_up, %{pickup_ref: "new"}))
  end

  test "conflicts, incorrect source/tenant, stale revisions and duplicate replay refuse" do
    {:ok, initial} = LastMile.new("merchant", "r")
    ready_event = event(initial, "ready", :ready)
    {:ok, ready, :accepted} = LastMile.apply(initial, "merchant", :commerce, ready_event)
    assert {:ok, ready, :duplicate} = LastMile.apply(ready, "merchant", :commerce, ready_event)
    assert {:ok, ready} = LastMile.replay(initial, "merchant", [{:commerce, ready_event}, {:commerce, ready_event}])

    assert {:error, :idempotency_conflict} = LastMile.apply(ready, "merchant", :dispatch, ready_event)
    assert {:error, :wrong_merchant} = LastMile.apply(ready, "other", :dispatch, event(ready, "a", :picked_up))
    assert {:error, :stale_last_mile_version} = LastMile.apply(ready, "merchant", :dispatch, %{ready_event | id: "other"})
    assert {:error, :invalid_reference} =
             LastMile.apply(ready, "merchant", :dispatch, event(ready, "pick", :picked_up, %{pickup_ref: ""}))
  end

  test "exception requires an independently referenced resolution, not silent timeout" do
    {:ok, initial} = LastMile.new("merchant", "r")
    ready = advance(initial, "merchant", :commerce, "ready", :ready)
    moving = advance(ready, "merchant", :dispatch, "pickup", :picked_up, %{pickup_ref: "proof"})
    exception = advance(moving, "merchant", :dispatch, "problem", :exception, %{reason_ref: "issue"})
    assert exception.phase == :exception

    assert {:error, :invalid_transition_or_authority} =
             LastMile.apply(exception, "merchant", :dispatch, event(exception, "drop", :delivered, %{delivery_proof_ref: "p"}))

    uncertain = advance(exception, "merchant", :observer, "unknown", :uncertain)
    assert uncertain.phase == :exception
    assert uncertain.held?
    resumed = advance(uncertain, "merchant", :dispatch, "resolved", :resolved, %{resolution_ref: "resolution"})
    assert resumed.phase == :in_transit
    assert resumed.held?
  end
end
