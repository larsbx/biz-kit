defmodule RestaurantHost.Web.BoardLive do
  @moduledoc """
  The kitchen board: every open order, newest last, with the steps it can take
  now. A step is signed with this board's device key and admitted by the Log;
  the board shows what the Log holds, never its own guess. Only a paired board
  (`PairController`) can act.

  A ready delivery order can request a driver; its card then follows the
  handoff as Dispatch signs it. Cancel withdraws a live request first
  (`Orders.cancel/4`); once Dispatch has accepted, the order cancels only after
  Dispatch confirms. A dispatched order stays listed, with no actions.
  """
  use Phoenix.LiveView

  alias RestaurantHost.{Orders, Restaurant}

  @labels %{
    accept: "Accept",
    start_preparing: "Start preparing",
    mark_ready: "Ready",
    complete: "Picked up",
    cancel: "Cancel",
    request_transport: "Request driver"
  }

  @handoff %{
    requested: "Driver requested",
    accepted: "Driver assigned",
    withdrawn: "Driver request withdrawn; Cancel to finish",
    cancel_pending: "Cancellation pending with Dispatch",
    in_transit: "Out for delivery",
    rejected: "Dispatch rejected",
    cancelled: "Dispatch confirmed the cancellation; Cancel to finish",
    failed_before_pickup: "Driver failed"
  }

  @refusals %{
    transport_pending: "A driver request is open; cancel withdraws it first.",
    transport_already_requested: "A driver is already requested.",
    no_transport_authority: "Delivery is not set up for this restaurant.",
    order_not_ready: "Request a driver once the order is ready."
  }

  @impl true
  def mount(_params, session, socket) do
    r = Restaurant.current()
    board = session["board"]

    if Map.has_key?(r.boards, board) do
      if connected?(socket), do: Orders.subscribe()

      {:ok,
       socket |> assign(page_title: "Kitchen", restaurant: r, board: board, error: nil) |> load()}
    else
      {:ok, assign(socket, page_title: "Kitchen", board: nil)}
    end
  end

  @impl true
  def handle_event("act", %{"id" => id, "action" => name}, %{assigns: %{board: board}} = socket)
      when is_binary(board) do
    r = socket.assigns.restaurant

    with %{} = order <- Orders.get(r, id),
         action when not is_nil(action) <-
           Enum.find(buttons(order), &(Atom.to_string(&1) == name)),
         ok when ok in [:ok, {:ok, :pending}] <- act(r, board, order, action) do
      {:noreply, socket |> assign(error: nil) |> load()}
    else
      {:error, reason} when is_map_key(@refusals, reason) ->
        {:noreply, socket |> assign(error: @refusals[reason]) |> load()}

      _ ->
        {:noreply,
         socket |> assign(error: "That order changed; the board is up to date now.") |> load()}
    end
  end

  defp act(r, board, order, :cancel), do: Orders.cancel(r, board, order.id, reason(:cancel))

  defp act(r, board, order, :request_transport),
    do: Orders.request_transport(r, board, order.id, order.version)

  defp act(r, board, order, action),
    do: Orders.step(r, board, order.id, action, order.version, reason(action))

  # The kitchen's actions, Cancel while a live driver request can be withdrawn,
  # and Request driver.
  defp buttons(order) do
    withdraw = if :withdraw_transport in order.handoff_actions, do: [:cancel], else: []
    order.actions ++ withdraw ++ (order.handoff_actions -- [:withdraw_transport])
  end

  defp handoff(%{handoff: %{view: view} = h}) when is_map_key(@handoff, view),
    do:
      @handoff[view] <>
        if(h.reason && view in [:rejected, :failed_before_pickup], do: ": " <> h.reason, else: "")

  defp handoff(_), do: nil

  # Ledger text, shown only when it is text: a signed snapshot is checked for
  # shape, not for the type of every display field.
  defp text(value) when is_binary(value), do: value
  defp text(_), do: ""

  @impl true
  def handle_info({:coop_ledger, _}, socket), do: {:noreply, load(socket)}

  defp reason(:cancel), do: "Cancelled at the kitchen board"
  defp reason(_), do: nil

  defp load(socket) do
    orders =
      Orders.list(socket.assigns.restaurant)
      |> Enum.reject(&OrderCore.Lifecycle.terminal?(&1.state))

    assign(socket, orders: orders)
  end

  defp money(minor, currency), do: Money.to_string!(Money.from_integer(minor, currency))
  defp label(action), do: Map.get(@labels, action, to_string(action))

  @impl true
  def render(%{board: nil} = assigns) do
    ~H"""
    <h1>Kitchen</h1>
    <p id="unpaired">This board is not paired.</p>
    """
  end

  def render(assigns) do
    ~H"""
    <h1>Kitchen</h1>
    <p :if={@error} role="alert">{@error}</p>
    <p :if={@orders == []} id="empty">No open orders.</p>
    <article :for={order <- @orders} id={"order-#{order.id}"} class="order">
      <div class="row">
        <strong>{order.pickup_name || "Guest"}</strong>
        <span class="state">{order.state}</span>
        <span>{money(order.total, @restaurant.currency)} cash</span>
      </div>
      <ul>
        <li :for={line <- order.lines}>{line["quantity"]} × {text(line["name"])}</li>
      </ul>
      <p :if={order.fulfillment == :delivery} class="delivery">
        Deliver to {text(order.delivery["address"])}<span :if={is_binary(order.delivery["notes"])}> ({order.delivery[
          "notes"
        ]})</span>
      </p>
      <p :if={handoff(order)} class="handoff">{handoff(order)}</p>
      <button
        :for={action <- buttons(order)}
        phx-click="act"
        phx-value-id={order.id}
        phx-value-action={action}
        id={"#{action}-#{order.id}"}
      >
        {label(action)}
      </button>
    </article>
    """
  end
end
