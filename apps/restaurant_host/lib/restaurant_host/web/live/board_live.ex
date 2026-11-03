defmodule RestaurantHost.Web.BoardLive do
  @moduledoc """
  The kitchen board: every open order, newest last, with the steps it can take
  now. A step is signed with this board's device key and admitted by the Log;
  the board shows what the Log holds, never its own guess. Only a paired board
  (`PairController`) can act.
  """
  use Phoenix.LiveView

  alias RestaurantHost.{Orders, Restaurant}

  @labels %{
    accept: "Accept",
    start_preparing: "Start preparing",
    mark_ready: "Ready",
    complete: "Picked up",
    cancel: "Cancel"
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
         action when not is_nil(action) <- Enum.find(order.actions, &(Atom.to_string(&1) == name)),
         :ok <- Orders.step(r, board, id, action, order.version, reason(action)) do
      {:noreply, socket |> assign(error: nil) |> load()}
    else
      _ ->
        {:noreply,
         socket |> assign(error: "That order changed; the board is up to date now.") |> load()}
    end
  end

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
        <li :for={line <- order.lines}>{line["quantity"]} × {line["name"]}</li>
      </ul>
      <button
        :for={action <- order.actions}
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
