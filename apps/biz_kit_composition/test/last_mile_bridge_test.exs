defmodule BizKit.LastMileBridgeTest do
  use ExUnit.Case, async: true

  alias BizKit.LastMileBridge
  alias DispatchCore.LastMile
  alias FulfillmentCore

  defp source_event(state, id, op, extras \\ %{}) do
    Map.merge(%{id: id, expected_version: state.version, op: op}, extras)
  end

  defp move(state, who, id, op, extras \\ %{}) do
    {:ok, next, :accepted} =
      LastMile.apply(state, "merchant", who, source_event(state, id, op, extras))

    next
  end

  defp base do
    {:ok, fulfillment} = FulfillmentCore.new("merchant", "request-1", "order-1", "courier")

    {:ok, fulfillment, :accepted} =
      FulfillmentCore.apply(fulfillment, "merchant", :dispatch, %{
        id: "accept-1",
        expected_version: 0,
        op: :accept,
        transport_ref: "transport-1"
      })

    {:ok, initial} = LastMile.new("merchant", "transport-1")
    ready = move(initial, :commerce, "ready", :ready)
    picked = move(ready, :dispatch, "pickup", :picked_up, %{pickup_ref: "pickup-proof"})
    {fulfillment, picked}
  end

  defp trusted(last_mile, id) do
    %{
      merchant: "merchant",
      verified_transport_ref: "transport-1",
      verified_source: :dispatch,
      last_mile_version: last_mile.version,
      event_id: id,
      verified_pickup_ref: "pickup-proof",
      verified_delivery_proof_ref: "delivery-proof"
    }
  end

  test "pickup produces only a source-bound in-transit candidate" do
    {fulfillment, picked} = base()

    assert {:ok, proposal} =
             LastMileBridge.preview(fulfillment, picked, trusted(picked, "move-1"))

    assert proposal.kind == :unsigned_fulfillment_candidate
    assert proposal.source_last_mile_version == picked.version
    assert proposal.fulfillment_event.op == :in_transit
    assert proposal.resulting_phase == :in_transit
    assert fulfillment.phase == :accepted
    assert picked.phase == :in_transit
  end

  test "delivery proof is source-bound and FulfillmentCore validates it" do
    {fulfillment, picked} = base()
    {:ok, moving, :accepted} =
      FulfillmentCore.apply(fulfillment, "merchant", :dispatch, %{
        id: "move-1",
        expected_version: fulfillment.version,
        op: :in_transit
      })

    delivered = move(picked, :dispatch, "delivery", :delivered, %{
      delivery_proof_ref: "delivery-proof"
    })

    assert {:ok, proposal} =
             LastMileBridge.preview(moving, delivered, trusted(delivered, "delivery-1"))

    assert proposal.fulfillment_event.op == :delivered
    assert proposal.fulfillment_event.proof_ref == "delivery-proof"
    assert proposal.resulting_phase == :delivered
    assert moving.phase == :in_transit
  end

  test "tampered identity, source, version or pickup reference is rejected" do
    {fulfillment, picked} = base()
    verified = trusted(picked, "move-1")

    assert {:error, :wrong_transport_scope} =
             LastMileBridge.preview(fulfillment, picked, %{verified | merchant: "other"})

    assert {:error, :wrong_transport_scope} =
             LastMileBridge.preview(fulfillment, picked, %{verified | verified_transport_ref: "other"})

    assert {:error, :unverified_transport_source} =
             LastMileBridge.preview(fulfillment, picked, %{verified | verified_source: :commerce})

    assert {:error, :stale_transport_version} =
             LastMileBridge.preview(fulfillment, picked, %{verified | last_mile_version: 0})

    assert {:error, :unverified_pickup_proof} =
             LastMileBridge.preview(fulfillment, picked, %{verified | verified_pickup_ref: "forged"})
  end

  test "cancelled fulfillment does not discard late transport delivery evidence" do
    {fulfillment, picked} = base()
    {:ok, moving, :accepted} =
      FulfillmentCore.apply(fulfillment, "merchant", :dispatch, %{
        id: "move",
        expected_version: fulfillment.version,
        op: :in_transit
      })

    {:ok, cancelled, :accepted} =
      FulfillmentCore.apply(moving, "merchant", :commerce, %{
        id: "cancel",
        expected_version: moving.version,
        op: :cancel
      })

    delivered = move(picked, :dispatch, "delivery", :delivered, %{
      delivery_proof_ref: "delivery-proof"
    })

    assert {:error, :pending_cancellation_reconciliation} =
             LastMileBridge.preview(cancelled, delivered, trusted(delivered, "late-proof"))

    assert delivered.phase == :delivered
    assert cancelled.phase == :cancel_requested
  end

  test "no early delivered event or missing transport proof can be promoted" do
    {fulfillment, picked} = base()

    assert {:error, :no_corresponding_fulfillment_transition} =
             LastMileBridge.preview(
               fulfillment,
               %{picked | phase: :ready_for_pickup},
               trusted(picked, "early")
             )

    assert {:error, :unverified_pickup_proof} =
             LastMileBridge.preview(
               fulfillment,
               %{picked | pickup_ref: nil},
               trusted(picked, "no-proof")
             )
  end
end
