defmodule RestaurantHost.DeliveryCodes do
  @moduledoc false

  def code(restaurant, order_id, phase) when phase in ["picked_up", "delivered"] do
    key = RestaurantHost.Web.Endpoint.config(:secret_key_base)

    message =
      Enum.join(
        ["restaurant-delivery-v1", restaurant.chapter, restaurant.merchant, order_id, phase],
        ":"
      )

    :crypto.mac(:hmac, :sha256, key, message)
    |> binary_part(0, 16)
    |> Base.url_encode64(padding: false)
  end

  def request(restaurant, order_id) do
    %{
      "request_id" => order_id,
      "profile" => "automatic-v1",
      "site" => restaurant.delivery_site,
      "pickup_digest" => digest(code(restaurant, order_id, "picked_up")),
      "dropoff_digest" => digest(code(restaurant, order_id, "delivered"))
    }
  end

  defp digest(code), do: Base.encode16(:crypto.hash(:sha256, code), case: :lower)
end
