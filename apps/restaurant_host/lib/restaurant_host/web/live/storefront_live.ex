defmodule RestaurantHost.Web.StorefrontLive do
  @moduledoc """
  The storefront: pick from the menu, give a name for pickup, place the order
  and pay cash at the counter. Where delivery is offered (`Orders.delivery?/1`)
  the guest may instead give an address and pay cash on delivery; the fee is
  itemized. After placing, the page follows the order's state as the Log
  admits each kitchen and Dispatch step.
  """
  use Phoenix.LiveView

  alias CoopSubstrate.ULID
  alias RestaurantHost.{Orders, Restaurant}

  @status %{
    placed: "Received",
    accepted: "Accepted",
    preparing: "Being prepared",
    ready: "Ready for pickup",
    completed: "Picked up",
    cancelled: "Cancelled"
  }

  @delivery_status %{
    dispatched: "On its way",
    completed: "Delivered",
    failed: "Delivery failed"
  }

  @impl true
  def mount(_params, _session, socket) do
    r = Restaurant.current()

    {:ok,
     assign(socket,
       page_title: "Order for pickup",
       restaurant: r,
       delivery?: Orders.delivery?(r),
       menu: Orders.menu(r),
       basket: %{},
       priced: nil,
       name: "",
       fulfillment: "pickup",
       address: "",
       notes: "",
       key: ULID.generate(),
       order: nil,
       error: nil
     )}
  end

  @impl true
  def handle_event("add", %{"id" => id}, socket), do: {:noreply, rebasket(socket, id, 1)}
  def handle_event("remove", %{"id" => id}, socket), do: {:noreply, rebasket(socket, id, -1)}

  def handle_event("form", params, socket) do
    fields = Map.take(params, ~w(name fulfillment address notes))

    socket =
      assign(socket,
        name: Map.get(fields, "name", socket.assigns.name),
        fulfillment: fulfillment(socket, Map.get(fields, "fulfillment")),
        address: Map.get(fields, "address", socket.assigns.address),
        notes: Map.get(fields, "notes", socket.assigns.notes)
      )

    {:noreply, rebasket(socket, nil, 0)}
  end

  def handle_event("place", %{"name" => name} = params, socket) do
    %{restaurant: r, basket: basket, key: key} = socket.assigns

    delivery =
      if fulfillment(socket, params["fulfillment"]) == "delivery",
        do: %{address: params["address"], notes: params["notes"]}

    case Orders.place(r, basket, String.trim(name), key, delivery) do
      {:ok, id} ->
        if connected?(socket), do: Orders.subscribe()
        {:noreply, assign(socket, order: Orders.get(r, id), error: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, error: message(reason))}
    end
  end

  @impl true
  def handle_info({:coop_ledger, _}, %{assigns: %{order: %{id: id}}} = socket),
    do: {:noreply, assign(socket, order: Orders.get(socket.assigns.restaurant, id))}

  def handle_info(_, socket), do: {:noreply, socket}

  # Delivery is chosen only where it is offered.
  defp fulfillment(%{assigns: %{delivery?: true}}, "delivery"), do: "delivery"
  defp fulfillment(%{assigns: %{fulfillment: current}}, nil), do: current
  defp fulfillment(_, _), do: "pickup"

  defp rebasket(socket, id, delta) do
    basket =
      if id,
        do:
          socket.assigns.basket
          |> Map.update(id, max(delta, 0), &max(&1 + delta, 0))
          |> Map.reject(fn {_, q} -> q == 0 end),
        else: socket.assigns.basket

    priced =
      case Orders.price(
             socket.assigns.restaurant,
             basket,
             String.to_existing_atom(socket.assigns.fulfillment)
           ) do
        {:ok, priced} when basket != %{} -> priced
        _ -> nil
      end

    assign(socket, basket: basket, priced: priced)
  end

  defp message(:no_lines), do: "Add something to your order first."
  defp message(:invalid_checkout_command), do: "Please give a name for pickup."
  defp message(:invalid_address), do: "Please give a delivery address."
  defp message(:delivery_unavailable), do: "Delivery is not available right now."
  defp message(_), do: "We could not place that order. Please try again."

  defp money(m), do: Money.to_string!(m)

  defp status(%{fulfillment: :delivery, state: :ready, handoff: %{view: view}})
       when view in [:withdrawn, :cancel_pending, :cancelled],
       do: "Cancellation requested"

  defp status(%{fulfillment: :delivery, state: :ready}), do: "Waiting for a driver"

  defp status(%{fulfillment: :delivery, state: state}) when is_map_key(@delivery_status, state),
    do: @delivery_status[state]

  defp status(%{state: state}), do: Map.get(@status, state, to_string(state))

  @impl true
  def render(%{order: %{} = order} = assigns) do
    assigns =
      assign(assigns,
        status: status(order),
        payable: if(order.fulfillment == :delivery, do: "on delivery", else: "at pickup")
      )

    ~H"""
    <h1>Thanks, {@order.pickup_name}</h1>
    <p>Order <code id="order-id">{@order.id}</code></p>
    <p id="order-status">{@status}</p>
    <p>Pay {money(Money.from_integer(@order.total, @restaurant.currency))} in cash {@payable}.</p>
    """
  end

  def render(assigns) do
    ~H"""
    <h1>Order for pickup</h1>
    <section id="menu">
      <div :for={item <- @menu} class="row">
        <span>{item.name}</span>
        <span>{money(item.price)}</span>
        <button phx-click="add" phx-value-id={item.id} id={"add-#{item.id}"}>Add</button>
      </div>
    </section>

    <section :if={@priced} id="basket">
      <h2>Your order</h2>
      <div :for={line <- @priced.lines} class="row">
        <span>{line.quantity} × {line.name}</span>
        <span>{money(line.subtotal)}</span>
        <button phx-click="remove" phx-value-id={line.item_id}>Remove one</button>
      </div>
      <div class="row"><span>Tax</span><span>{money(@priced.tax)}</span></div>
      <div :if={@fulfillment == "delivery"} class="row">
        <span>Delivery fee</span><span id="delivery-fee">{money(@priced.adjustments.delivery_fee)}</span>
      </div>
      <div class="row"><strong>Total</strong><strong id="total">{money(@priced.total)}</strong></div>

      <form id="place" phx-change="form" phx-submit="place">
        <fieldset :if={@delivery?}>
          <label>
            <input
              type="radio"
              name="fulfillment"
              value="pickup"
              id="fulfillment-pickup"
              checked={@fulfillment == "pickup"}
            /> Pickup
          </label>
          <label>
            <input
              type="radio"
              name="fulfillment"
              value="delivery"
              id="fulfillment-delivery"
              checked={@fulfillment == "delivery"}
            /> Delivery
          </label>
        </fieldset>
        <label>Name <input name="name" value={@name} maxlength="80" required /></label>
        <label :if={@fulfillment == "delivery"}>
          Address
          <input name="address" id="delivery-address" value={@address} maxlength="200" required />
        </label>
        <label :if={@fulfillment == "delivery"}>
          Notes for the driver
          <input name="notes" id="delivery-notes" value={@notes} maxlength="200" />
        </label>
        <button type="submit">
          Place order, pay cash {if @fulfillment == "delivery", do: "on delivery", else: "at pickup"}
        </button>
      </form>
    </section>

    <p :if={@error} id="error" role="alert">{@error}</p>
    """
  end
end
