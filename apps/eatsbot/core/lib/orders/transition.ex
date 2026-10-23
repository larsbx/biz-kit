defmodule EatsbotCore.Orders.Transition do
  @moduledoc """
  Moves an order to `opts[:to]` if `Transitions.legal?/3` allows it, and appends the
  step to `OrderStateChange` in the same transaction (I₃, I₆).

  Each step gets the next `sequence` number; the unique `(order_id, sequence)` identity
  makes two concurrent transitions of one order fail rather than both commit.
  """
  use Ash.Resource.Change

  alias EatsbotCore.Orders.{ActorIn, OrderStateChange, Transitions}

  @system %{access_level: :system}

  @impl true
  def change(changeset, opts, context) do
    %{state: from, fulfillment: fulfillment} = changeset.data
    to = Keyword.fetch!(opts, :to)

    if Transitions.legal?(fulfillment, from, to) do
      changeset
      |> Ash.Changeset.force_change_attribute(:state, to)
      |> Ash.Changeset.after_action(fn changeset, order ->
        record_step(
          order,
          from,
          to,
          Ash.Changeset.get_argument(changeset, :reason),
          context.actor
        )
      end)
    else
      Ash.Changeset.add_error(changeset,
        field: :state,
        message: "cannot move a %{fulfillment} order from %{from} to %{to}",
        vars: [fulfillment: fulfillment, from: from, to: to]
      )
    end
  end

  defp record_step(order, from, to, reason, actor) do
    sequence =
      OrderStateChange
      |> Ash.Query.for_read(:for_order, %{order_id: order.id}, actor: @system)
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
      actor: @system
    )
    |> Ash.create()
    |> case do
      {:ok, _step} -> {:ok, order}
      {:error, error} -> {:error, error}
    end
  end
end
