defmodule RestaurantHost.Web.AccountLive do
  @moduledoc false
  use Phoenix.LiveView

  alias RestaurantHost.{DeliveryCodes, Orders, Restaurant}
  alias RestaurantHost.Web.AuthController

  @impl true
  def mount(_params, session, socket) do
    case AuthController.principal(session["restaurant_identity"]) do
      {:ok, principal} ->
        restaurant = Restaurant.current()
        orders = restaurant |> Orders.for_principal(principal) |> Enum.reverse()
        {:ok, assign(socket, page_title: "Your orders", orders: orders, restaurant: restaurant)}

      {:error, _} ->
        {:ok, redirect(socket, to: "/")}
    end
  end

  defp money(order) do
    case Money.validate_currency(order.currency) do
      {:ok, currency} -> Money.to_string!(Money.from_integer(order.total, currency))
      _ -> order.currency
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1>Your orders</h1>
    <p><a href="/">Back to ordering</a></p>
    <p :if={@orders == []}>You have no orders with this restaurant.</p>
    <ul>
      <li :for={order <- @orders} id={"account-order-#{order.id}"}>
        <code>{order.id}</code>
        · {order.state} · {money(order)}
        <span :if={order.delivery_site && order.state not in [:completed, :cancelled]}>
          · Drop-off code <code>{DeliveryCodes.code(@restaurant, order.id, "delivered")}</code>
        </span>
      </li>
    </ul>
    """
  end
end
