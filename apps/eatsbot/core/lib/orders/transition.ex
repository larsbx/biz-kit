defmodule EatsbotCore.Orders.Transition do
  @moduledoc """
  Moves an order to `opts[:to]` if `Transitions.legal?/3` allows it, and appends the
  step to `OrderStateChange` in the same transaction (I₃, I₆).

  Each step gets the next `sequence` number; the unique `(order_id, sequence)` identity
  makes two concurrent transitions of one order fail rather than both commit.

  For a delivery order (I₈, see `EatsbotCore.Orders.DeliveryCoupling`), an edge the
  delivery owns is only accepted when it arrives from `SyncFromDelivery`, and an edge
  the order owns mirrors its step onto the delivery in the same transaction.
  """
  use Ash.Resource.Change

  alias EatsbotCore.Orders.{ActorIn, DeliveryCoupling, OrderStateChange, Transitions}

  @impl true
  def change(changeset, opts, context) do
    %{state: from, fulfillment: fulfillment} = changeset.data
    to = Keyword.fetch!(opts, :to)

    cond do
      not Transitions.legal?(fulfillment, from, to) ->
        add_error(changeset, "cannot move a %{fulfillment} order from %{from} to %{to}",
          fulfillment: fulfillment,
          from: from,
          to: to
        )

      fulfillment == :delivery and DeliveryCoupling.order_edge_owner(from, to) == :delivery and
          changeset.context[:order_delivery_sync] != :from_delivery ->
        add_error(changeset, "a delivery order moves to %{to} only through its delivery", to: to)

      true ->
        changeset
        |> Ash.Changeset.force_change_attribute(:state, to)
        |> Ash.Changeset.after_action(fn changeset, order ->
          reason = Ash.Changeset.get_argument(changeset, :reason)

          with {:ok, order} <- record_step(order, from, to, reason, context.actor),
               do: mirror_to_delivery(order, changeset, from, to)
        end)
    end
  end

  defp add_error(changeset, message, vars),
    do: Ash.Changeset.add_error(changeset, field: :state, message: message, vars: vars)

  defp record_step(order, from, to, reason, actor) do
    sequence =
      OrderStateChange
      |> Ash.Query.for_read(:for_order, %{order_id: order.id}, actor: ActorIn.system())
      |> Ash.count!()
      |> Kernel.+(1)

    OrderStateChange
    |> Ash.Changeset.for_create(
      :record,
      %{
        order_id: order.id,
        sequence: sequence,
        from: from,
        to: to,
        reason: reason,
        actor_type: ActorIn.actor_type(actor)
      },
      actor: ActorIn.system()
    )
    |> Ash.create()
    |> case do
      {:ok, _step} -> {:ok, order}
      {:error, error} -> {:error, error}
    end
  end

  # A step that came from the delivery is already mirrored; only order-owned edges move it.
  defp mirror_to_delivery(%{fulfillment: :delivery} = order, changeset, from, to) do
    if changeset.context[:order_delivery_sync] == :from_delivery do
      {:ok, order}
    else
      %{delivery: delivery} = Ash.load!(order, :delivery, actor: ActorIn.system())

      case DeliveryCoupling.delivery_effect(delivery.state, from, to) do
        :none ->
          {:ok, order}

        {:move, state} ->
          delivery
          |> Ash.Changeset.for_update(:update_state, %{state: state},
            actor: ActorIn.system(),
            context: %{order_delivery_sync: :from_order}
          )
          |> Ash.update()
          |> case do
            {:ok, _delivery} -> {:ok, order}
            {:error, error} -> {:error, error}
          end
      end
    end
  end

  defp mirror_to_delivery(order, _changeset, _from, _to), do: {:ok, order}
end
