defmodule FulfillmentCore.WireTest do
  use ExUnit.Case, async: true

  alias FulfillmentCore.Wire

  @transport %{merchant: "restaurant", request_id: "request-1", producer: :dispatch}
  @commerce %{merchant: "restaurant", request_id: "request-1", producer: :commerce}

  defp payload(operation, extras \\ %{}) do
    Map.merge(
      %{
        "schema" => "bizkit.fulfillment.event.v1",
        "merchant" => "restaurant",
        "request_id" => "request-1",
        "id" => "event-1",
        "expected_version" => 0,
        "op" => operation
      },
      extras
    )
  end

  test "only a dispatch producer can accept transport with a typed reference" do
    wire = payload("accept", %{"transport_ref" => "trip-1"})
    assert {:ok, :dispatch, event} = Wire.decode(wire, @transport)
    assert event == %{id: "event-1", expected_version: 0, op: :accept,
                      transport_ref: "trip-1"}

    {:ok, state} = FulfillmentCore.new("restaurant", "request-1", "order-1", "courier")
    assert {:ok, accepted, :accepted} =
             FulfillmentCore.apply(state, "restaurant", :dispatch, event)

    assert accepted.transport_ref == "trip-1"
    assert {:error, :wrong_event_authority} = Wire.decode(wire, @commerce)
  end

  test "commerce can cancel but may not claim delivered proof" do
    assert {:ok, :commerce, %{op: :cancel}} = Wire.decode(payload("cancel"), @commerce)

    assert {:error, :wrong_event_authority} =
             Wire.decode(payload("delivered", %{"proof_ref" => "verified"}), @commerce)
  end

  test "rejects scope confusion, asserted actor, extra keys and altered version" do
    wire = payload("accept", %{"transport_ref" => "trip-1"})

    assert {:error, :wrong_fulfillment_scope} =
             Wire.decode(%{wire | "merchant" => "another"}, @transport)

    assert {:error, :wrong_fulfillment_scope} =
             Wire.decode(%{wire | "request_id" => "another"}, @transport)

    assert {:error, :invalid_fulfillment_shape} =
             Wire.decode(Map.put(wire, "producer", "dispatch"), @transport)

    assert {:error, :invalid_fulfillment_shape} =
             Wire.decode(%{wire | "schema" => "v2"}, @transport)

    assert {:error, :invalid_fulfillment_value} =
             Wire.decode(%{wire | "expected_version" => 1.5}, @transport)

    assert {:error, :invalid_fulfillment_value} =
             Wire.decode(%{wire | "expected_version" => 9_007_199_254_740_992}, @transport)
  end

  test "unknown op and untrusted producer are not converted into authority" do
    assert {:error, :unsupported_fulfillment_operation} =
             Wire.decode(payload("grant"), @transport)

    assert {:error, :invalid_fulfillment_event} =
             Wire.decode(payload("accept", %{"transport_ref" => "x"}), %{
               merchant: "restaurant",
               request_id: "request-1",
               producer: "dispatch"
             })
  end
end
