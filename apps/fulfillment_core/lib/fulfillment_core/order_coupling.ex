defmodule FulfillmentCore.OrderCoupling do
  @moduledoc """
  Pure legacy order/delivery coupling policy (I₈), not a transport writer.

  Projection helpers retain the pinned alpha relation and mirror values, but
  refuse the opposite authority's edges before computing a mirror. They do not
  validate a live transition. Use `step/4` to validate the edge, source coupling
  and resulting invariant together. A host must verify producer authority and
  atomically admit both projections; no callback may recursively mirror a mirror.
  This legacy relation does not certify delivery evidence or resolve uncertain
  cancellation. FulfillmentCore's existing cancel_requested protocol remains
  authoritative for handoff reconciliation.
  """

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
  @mirror %{preparing: "In_Preparation", ready: "Ready_To_Pickup", cancelled: "Delivery_Aborted"}
  @order_edges [
    {:placed, :accepted},
    {:accepted, :preparing},
    {:preparing, :ready},
    {:ready, :dispatched},
    {:dispatched, :completed},
    {:dispatched, :failed},
    {:placed, :cancelled},
    {:accepted, :cancelled},
    {:preparing, :cancelled},
    {:ready, :cancelled}
  ]
  @delivery_edges [
    {"Init", "In_Preparation"},
    {"Init", "Delivery_Aborted"},
    {"In_Preparation", "Ready_To_Pickup"},
    {"In_Preparation", "Delivery_Aborted"},
    {"Ready_To_Pickup", "In_Delivery"},
    {"Ready_To_Pickup", "Delivery_Aborted"},
    {"In_Delivery", "Delivery_Done"},
    {"In_Delivery", "Stale_Delivery_With_Problems"},
    {"In_Delivery", "Delivery_With_Problems"},
    {"Delivery_With_Problems", "In_Delivery"},
    {"Delivery_With_Problems", "Stale_Delivery_With_Problems"},
    {"Delivery_Done", "Stale_Delivery_Done"},
    {"Delivery_Aborted", "Stale_Delivery_Aborted"}
  ]

  def coupled?(order, delivery), do: order in Map.get(@alpha, delivery, [])
  def order_edge_owner(_, to) when to in [:dispatched, :completed, :failed], do: :delivery
  def order_edge_owner(_, _), do: :order

  def delivery_edge_owner(_, to)
      when to in ["In_Preparation", "Ready_To_Pickup", "Delivery_Aborted"],
      do: :order

  def delivery_edge_owner(_, _), do: :delivery

  def delivery_effect(delivery, from, to) do
    cond do
      order_edge_owner(from, to) != :order ->
        {:error, :delivery_owned}

      not Map.has_key?(@alpha, delivery) or {from, to} not in @order_edges ->
        {:error, :invalid_transition}

      coupled?(to, delivery) ->
        :none

      Map.has_key?(@mirror, to) ->
        {:move, Map.fetch!(@mirror, to)}

      true ->
        {:error, :inconsistent_coupling}
    end
  end

  def order_effect(order, from, to) do
    cond do
      delivery_edge_owner(from, to) != :delivery ->
        {:error, :order_owned}

      {from, to} not in @delivery_edges ->
        {:error, :invalid_transition}

      coupled?(order, to) ->
        :none

      true ->
        case Map.get(@alpha, to) do
          [state] -> {:move, state}
          _ -> {:error, :inconsistent_coupling}
        end
    end
  end

  @doc "Validate a source pair and one owned edge; return both candidate projections."
  def step(order, delivery, :order, to) do
    with true <- coupled?(order, delivery),
         effect when effect == :none or elem(effect, 0) == :move <-
           delivery_effect(delivery, order, to) do
      next =
        case effect do
          :none -> delivery
          {:move, d} -> d
        end

      {:ok, %{order: to, delivery: next}}
    else
      false -> {:error, :inconsistent_coupling}
      error -> error
    end
  end

  def step(order, delivery, :delivery, to) do
    with true <- coupled?(order, delivery),
         effect when effect == :none or elem(effect, 0) == :move <-
           order_effect(order, delivery, to) do
      next =
        case effect do
          :none -> order
          {:move, o} -> o
        end

      {:ok, %{order: next, delivery: to}}
    else
      false -> {:error, :inconsistent_coupling}
      error -> error
    end
  end

  def step(_, _, _, _), do: {:error, :wrong_event_authority}
end
