defmodule RestaurantHost.Web.StorefrontLive do
  @moduledoc """
  The storefront: pick from the menu, give a name for pickup, place the order
  and pay cash at the counter. After placing, the page follows the order's
  state as the Log admits each kitchen step.
  """
  use Phoenix.LiveView

  alias CoopSubstrate.ULID
  alias RestaurantHost.{Orders, Restaurant}
  alias RestaurantHost.Web.AuthController

  @status %{
    placed: "Received",
    accepted: "Accepted",
    preparing: "Being prepared",
    ready: "Ready for pickup",
    completed: "Picked up",
    cancelled: "Cancelled"
  }

  @impl true
  def mount(_params, session, socket) do
    r = Restaurant.current() |> Restaurant.published_menu()
    reference = session["restaurant_identity"]

    {:ok,
     assign(socket,
       page_title: "Order for pickup",
       restaurant: r,
       menu: Orders.menu(r),
       identity_ref: reference,
       signed_in?: match?({:ok, _}, AuthController.principal(reference)),
       sign_in_available?: AuthController.enabled?(),
       basket: %{},
       priced: nil,
       name: "",
       key: ULID.generate(),
       order: nil,
       error: nil
     )}
  end

  @impl true
  def handle_event("add", %{"id" => id}, socket), do: {:noreply, rebasket(socket, id, 1)}
  def handle_event("remove", %{"id" => id}, socket), do: {:noreply, rebasket(socket, id, -1)}

  def handle_event("name", %{"name" => name}, socket) when is_binary(name),
    do: {:noreply, assign(socket, name: name)}

  def handle_event("place", %{"name" => name}, socket) when is_binary(name) do
    %{restaurant: r, basket: basket, key: key, identity_ref: reference} = socket.assigns

    with {:ok, principal} <- checkout_principal(reference),
         {:ok, id} <- Orders.place(r, basket, String.trim(name), key, principal) do
      if connected?(socket), do: Orders.subscribe()
      {:noreply, assign(socket, order: Orders.get(r, id), error: nil)}
    else
      {:error, :stale_menu} ->
        latest = Restaurant.published_menu(r)

        {:noreply,
         assign(socket,
           restaurant: latest,
           menu: Orders.menu(latest),
           basket: %{},
           priced: nil,
           error: "The menu changed. Please review it and add your items again."
         )}

      {:error, reason} ->
        {:noreply, assign(socket, error: message(reason))}
    end
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  defp checkout_principal(nil), do: {:ok, nil}

  defp checkout_principal(reference) do
    case AuthController.principal(reference) do
      {:ok, _} = principal -> principal
      {:error, _} -> {:error, :session_expired}
    end
  end

  @impl true
  def handle_info({:coop_ledger, _}, %{assigns: %{order: %{id: id}}} = socket),
    do: {:noreply, assign(socket, order: Orders.get(socket.assigns.restaurant, id))}

  def handle_info(_, socket), do: {:noreply, socket}

  defp rebasket(socket, id, delta) do
    if Enum.any?(socket.assigns.menu, &(&1.id == id)),
      do: update_basket(socket, id, delta),
      else: socket
  end

  defp update_basket(socket, id, delta) do
    basket =
      socket.assigns.basket
      |> Map.update(id, max(delta, 0), &max(&1 + delta, 0))
      |> Map.reject(fn {_, q} -> q == 0 end)

    priced =
      case Orders.price(socket.assigns.restaurant, basket) do
        {:ok, priced} when basket != %{} -> priced
        _ -> nil
      end

    assign(socket, basket: basket, priced: priced)
  end

  defp message(:session_expired), do: "Your session ended. Please sign in again."
  defp message(:no_lines), do: "Add something to your order first."
  defp message(:invalid_checkout_command), do: "Please give a name for pickup."
  defp message(_), do: "We could not place that order. Please try again."

  defp money(m), do: Money.to_string!(m)

  @impl true
  def render(%{order: %{} = order} = assigns) do
    assigns = assign(assigns, status: Map.get(@status, order.state, to_string(order.state)))

    ~H"""
    <h1>Thanks, {@order.pickup_name}</h1>
    <p>Order <code id="order-id">{@order.id}</code></p>
    <p id="order-status">{@status}</p>
    <p>Pay {money(Money.from_integer(@order.total, @restaurant.currency))} in cash at pickup.</p>
    """
  end

  def render(assigns) do
    ~H"""
    <h1>Order for pickup</h1>
    <nav :if={@sign_in_available?}>
      <a :if={!@signed_in?} href="/auth/login">Sign in</a>
      <a :if={@signed_in?} href="/account/orders">Your orders</a>
      <.form :if={@signed_in?} for={%{}} action="/auth/logout" method="post">
        <button type="submit">Sign out</button>
      </.form>
    </nav>
    <p :if={@menu == []}>Pickup ordering is currently unavailable.</p>
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
      <div class="row"><strong>Total</strong><strong id="total">{money(@priced.total)}</strong></div>

      <form id="place" phx-change="name" phx-submit="place">
        <label>Name for pickup <input name="name" value={@name} maxlength="80" required /></label>
        <button type="submit">Place order, pay cash at pickup</button>
      </form>
    </section>

    <p :if={@error} id="error" role="alert">{@error}</p>
    """
  end
end
