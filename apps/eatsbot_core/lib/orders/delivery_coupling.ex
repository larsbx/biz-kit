defmodule EatsbotCore.Orders.DeliveryCoupling do
  @moduledoc """
  Keeps a delivery order and its `Delivery` consistent (I₈): `order.state ∈ α(delivery.state)`.

  Every edge has exactly one owner, so the two sides never trigger each other in a loop:

  - the **order** owns the kitchen: accept, preparing, ready, and cancel (a delivery is
    aborted by cancelling its order)
  - the **delivery** owns dispatch: pickup, done, and unresolved problems

  An owned edge mirrors at most one step onto the other side, in the same transaction.
  The other side refuses the owner's edges when they are attempted directly.
  """

  alias EatsbotCore.Orders.Transitions

  @alpha %{
    "Init" => [:placed, :accepted],
    "In_Preparation" => [:preparing],
    "Ready_To_Pickup" => [:ready],
    "In_Delivery" => [:dispatched],
    "Delivery_With_Problems" => [:dispatched],
    "Delivery_Done" => [:completed],
    "Stale_Delivery_Done" => [:completed],
    "Delivery_Aborted" => [:cancelled],
    "Stale_Delivery_Aborted" => [:cancelled],
    "Stale_Delivery_With_Problems" => [:failed]
  }

  # The delivery state an order-owned order edge moves the delivery to.
  @delivery_mirror %{
    preparing: "In_Preparation",
    ready: "Ready_To_Pickup",
    cancelled: "Delivery_Aborted"
  }

  @delivery_owned_order_states [:dispatched, :completed, :failed]
  @order_owned_delivery_states Map.values(@delivery_mirror)

  @type delivery_state :: String.t()
  @type effect(state) :: :none | {:move, state}

  @doc "Whether an order in `order_state` is consistent with a delivery in `delivery_state`."
  @spec coupled?(Transitions.state(), delivery_state()) :: boolean()
  def coupled?(order_state, delivery_state),
    do: order_state in Map.get(@alpha, to_string(delivery_state), [])

  @doc "Which side may take the order edge `from → to` of a delivery order."
  @spec order_edge_owner(Transitions.state(), Transitions.state()) :: :order | :delivery
  def order_edge_owner(_from, to) when to in @delivery_owned_order_states, do: :delivery
  def order_edge_owner(_from, _to), do: :order

  @doc "Which side may take the delivery edge `from → to` of an order's delivery."
  @spec delivery_edge_owner(delivery_state(), delivery_state()) :: :order | :delivery
  def delivery_edge_owner(_from, to) when to in @order_owned_delivery_states, do: :order
  def delivery_edge_owner(_from, _to), do: :delivery

  @doc "The delivery step mirroring the order edge `from → to`, given the delivery's state."
  @spec delivery_effect(delivery_state(), Transitions.state(), Transitions.state()) ::
          effect(delivery_state())
  def delivery_effect(delivery_state, _from, to) do
    if coupled?(to, delivery_state),
      do: :none,
      else: {:move, Map.fetch!(@delivery_mirror, to)}
  end

  @doc "The order step mirroring the delivery edge `from → to`, given the order's state."
  @spec order_effect(Transitions.state(), delivery_state(), delivery_state()) ::
          effect(Transitions.state())
  def order_effect(order_state, _from, to) do
    if coupled?(order_state, to),
      do: :none,
      else: {:move, @alpha |> Map.fetch!(to) |> single!()}
  end

  defp single!([state]), do: state
end
