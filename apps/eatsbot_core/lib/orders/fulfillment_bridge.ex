defmodule EatsbotCore.Orders.FulfillmentBridge do
  @moduledoc """
  Read-only proposal from a placed restaurant delivery order.

  The restaurant order/kitchen state remains Eatsbot's authority. The shared
  fulfillment contract is a candidate, not an event append or provider call.
  """

  def propose(merchant, request_id, %{id: id, fulfillment: :delivery}) do
    FulfillmentCore.new(merchant, request_id, to_string(id), "restaurant-courier")
  end

  def propose(_, _, _), do: {:error, :not_a_delivery_order}
end
