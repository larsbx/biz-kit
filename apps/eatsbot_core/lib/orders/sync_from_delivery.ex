defmodule EatsbotCore.Orders.SyncFromDelivery do
  @moduledoc """
  The delivery's half of I₈ (see `EatsbotCore.Orders.DeliveryCoupling`).

  On a delivery that belongs to an order, an edge the order owns is only accepted when
  it arrives from `EatsbotCore.Orders.Transition`, and an edge the delivery owns
  mirrors its step onto the order in the same transaction. Deliveries without an
  order are untouched.

  Must run after any change that sets the delivery's new `state`.
  """
  use Ash.Resource.Change

  alias EatsbotCore.Orders.{ActorIn, DeliveryCoupling, Order}

  @order_actions %{
    dispatched: {:dispatch, %{}},
    completed: {:complete, %{}},
    failed: {:fail, %{reason: "delivery problem was not resolved"}}
  }

  @impl true
  def change(%{data: %{order_id: nil}} = changeset, _opts, _context), do: changeset

  def change(changeset, _opts, _context) do
    from = changeset.data.state
    to = Ash.Changeset.get_attribute(changeset, :state)

    cond do
      from == to ->
        changeset

      DeliveryCoupling.delivery_edge_owner(from, to) == :order and
          changeset.context[:order_delivery_sync] != :from_order ->
        Ash.Changeset.add_error(changeset,
          field: :state,
          message: "an order's delivery moves to %{to} only through its order",
          vars: [to: to]
        )

      changeset.context[:order_delivery_sync] == :from_order ->
        changeset

      true ->
        Ash.Changeset.after_action(changeset, fn _changeset, delivery ->
          mirror_to_order(delivery, from, to)
        end)
    end
  end

  defp mirror_to_order(delivery, from, to) do
    order = Ash.get!(Order, delivery.order_id, actor: ActorIn.system())

    case DeliveryCoupling.order_effect(order.state, from, to) do
      :none ->
        {:ok, delivery}

      {:move, state} ->
        {action, params} = Map.fetch!(@order_actions, state)

        order
        |> Ash.Changeset.for_update(action, params,
          actor: ActorIn.system(),
          context: %{order_delivery_sync: :from_delivery}
        )
        |> Ash.update()
        |> case do
          {:ok, _order} -> {:ok, delivery}
          {:error, error} -> {:error, error}
        end
    end
  end
end
