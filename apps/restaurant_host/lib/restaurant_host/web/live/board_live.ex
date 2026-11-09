defmodule RestaurantHost.Web.BoardLive do
  @moduledoc """
  The kitchen board: every open order, newest last, with the steps it can take
  now. A step is signed with this board's device key and admitted by the Log;
  the board shows what the Log holds, never its own guess. Only a paired board
  (`PairController`) can act.
  """
  use Phoenix.LiveView

  alias RestaurantHost.{Orders, Restaurant}
  alias RestaurantHost.Web.AuthController

  @access_check_ms 5_000

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

    socket =
      assign(socket,
        page_title: "Kitchen",
        restaurant: r,
        board: board,
        identity_ref: session["restaurant_identity"],
        error: nil,
        orders: []
      )

    if connected?(socket) and is_binary(board) and Map.has_key?(r.boards, board) do
      Orders.subscribe()
      Process.send_after(self(), :check_access, @access_check_ms)
    end

    {:ok, load(socket)}
  end

  @impl true
  def handle_event("act", %{"id" => id, "action" => name}, socket),
    do: act(socket, id, name, nil)

  def handle_event("cancel", %{"id" => id, "reason" => reason}, socket) when is_binary(reason),
    do: act(socket, id, "cancel", String.trim(reason))

  def handle_event(_, _, socket), do: {:noreply, socket}

  defp act(socket, id, name, reason) do
    %{restaurant: r, board: board} = socket.assigns

    with {:ok, staff} <- access(socket),
         %{} = order <- Orders.get(r, id),
         action when not is_nil(action) <- Enum.find(order.actions, &(Atom.to_string(&1) == name)),
         true <- action != :cancel or (is_binary(reason) and String.length(reason) in 1..200),
         :ok <- Orders.step(r, board, id, action, order.version, reason, staff) do
      {:noreply, socket |> assign(error: nil) |> load()}
    else
      _ ->
        {:noreply,
         socket
         |> assign(error: "The action was refused. Check the order and try again.")
         |> load()}
    end
  end

  @impl true
  def handle_info(:check_access, socket) do
    Process.send_after(self(), :check_access, @access_check_ms)
    {:noreply, load(socket)}
  end

  def handle_info({:coop_ledger, _}, socket), do: {:noreply, load(socket)}
  def handle_info(_, socket), do: {:noreply, socket}

  defp access(socket) do
    %{restaurant: r, board: board, identity_ref: reference} = socket.assigns

    if Restaurant.active_board?(r, board) do
      case Application.get_env(:restaurant_host, :staff_principals) do
        nil ->
          {:ok, nil}

        principals ->
          with {:ok, principal} <- AuthController.principal(reference),
               true <- principal in principals do
            {:ok, principal}
          else
            _ -> {:error, :staff_required}
          end
      end
    else
      {:error, :unpaired}
    end
  end

  defp load(socket) do
    case access(socket) do
      {:ok, _staff} ->
        orders =
          Orders.list(socket.assigns.restaurant)
          |> Enum.reject(&OrderCore.Lifecycle.terminal?(&1.state))

        assign(socket, access: :allowed, orders: orders)

      {:error, reason} ->
        assign(socket, access: reason, orders: [])
    end
  end

  defp money(minor, currency), do: Money.to_string!(Money.from_integer(minor, currency))
  defp label(action), do: Map.get(@labels, action, to_string(action))

  @impl true
  def render(%{access: :unpaired} = assigns) do
    ~H"""
    <h1>Kitchen</h1>
    <p id="unpaired">Pair an enrolled kitchen board to continue.</p>
    """
  end

  def render(%{access: :staff_required} = assigns) do
    ~H"""
    <h1>Kitchen</h1>
    <p id="staff-required">Sign in with an authorized staff account.</p>
    <a href="/auth/login?return=kitchen">Staff sign-in</a>
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
        :for={action <- order.actions -- [:cancel]}
        phx-click="act"
        phx-value-id={order.id}
        phx-value-action={action}
        id={"#{action}-#{order.id}"}
      >
        {label(action)}
      </button>
      <form :if={:cancel in order.actions} phx-submit="cancel" id={"cancel-#{order.id}"}>
        <input type="hidden" name="id" value={order.id} />
        <label>Cancellation reason <input name="reason" maxlength="200" required /></label>
        <button type="submit">Cancel order</button>
      </form>
    </article>
    """
  end
end
