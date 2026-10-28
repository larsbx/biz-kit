defmodule EatsbotCore.Orders.DeliveryCouplingTest do
  @moduledoc """
  Proof by enumeration that order and delivery stay coupled (I₈).

  Both machines are finite (8 order states × 10 delivery states), so each theorem
  below is checked on every coupled pair and every legal edge.
  """
  use ExUnit.Case, async: true

  alias EatsbotCore.Deliveries.Transitions, as: D
  alias EatsbotCore.Orders.DeliveryCoupling, as: C
  alias EatsbotCore.Orders.Transitions, as: O

  @delivery_states ~w(Init In_Preparation Ready_To_Pickup In_Delivery Delivery_With_Problems
                      Delivery_Done Delivery_Aborted Stale_Delivery_Aborted
                      Stale_Delivery_With_Problems Stale_Delivery_Done)

  defp coupled_pairs,
    do: for(o <- O.states(), d <- @delivery_states, C.coupled?(o, d), do: {o, d})

  defp order_edges(o), do: for(o2 <- O.next_states(:delivery, o), do: o2)
  defp delivery_edges(d), do: for(d2 <- @delivery_states, D.valid?(d, d2), do: d2)

  test "a new delivery order starts coupled: placed with Init" do
    assert C.coupled?(:placed, "Init")
  end

  test "α covers every delivery state, and every order state reachable for delivery" do
    for d <- @delivery_states, do: assert(Enum.any?(O.states(), &C.coupled?(&1, d)), d)

    for o <- O.states() do
      assert Enum.any?(@delivery_states, &C.coupled?(o, &1)), "#{o} has no delivery image"
    end
  end

  test "every legal edge has exactly one owner" do
    for {o, _d} <- coupled_pairs(),
        o2 <- order_edges(o),
        do: assert(C.order_edge_owner(o, o2) in [:order, :delivery])

    for {_o, d} <- coupled_pairs(),
        d2 <- delivery_edges(d),
        do: assert(C.delivery_edge_owner(d, d2) in [:order, :delivery])
  end

  test "an order-owned order edge keeps I₈, and its delivery step is legal" do
    for {o, d} <- coupled_pairs(), o2 <- order_edges(o), C.order_edge_owner(o, o2) == :order do
      d2 =
        case C.delivery_effect(d, o, o2) do
          :none -> d
          {:move, target} -> target
        end

      assert d2 == d or D.valid?(d, d2), "#{o}->#{o2} moves delivery #{d}->#{d2} illegally"
      assert C.coupled?(o2, d2), "#{o}->#{o2} with delivery #{d} breaks I₈ (#{d2})"
      assert d2 == d or C.delivery_edge_owner(d, d2) == :order
    end
  end

  test "a delivery-owned delivery edge keeps I₈, and its order step is legal" do
    for {o, d} <- coupled_pairs(),
        d2 <- delivery_edges(d),
        C.delivery_edge_owner(d, d2) == :delivery do
      o2 =
        case C.order_effect(o, d, d2) do
          :none -> o
          {:move, target} -> target
        end

      assert o2 == o or O.legal?(:delivery, o, o2),
             "#{d}->#{d2} moves order #{o}->#{o2} illegally"

      assert C.coupled?(o2, d2), "#{d}->#{d2} with order #{o} breaks I₈ (#{o2})"
      assert o2 == o or C.order_edge_owner(o, o2) == :delivery
    end
  end

  test "an edge taken on its non-owning side, without its mirror, would break I₈" do
    # This is why the non-owner must refuse such edges instead of applying them alone.
    for {o, d} <- coupled_pairs(),
        o2 <- order_edges(o),
        C.order_edge_owner(o, o2) == :delivery,
        do: refute(C.coupled?(o2, d), "order #{o}->#{o2} alone keeps I₈; it needs no owner")

    for {o, d} <- coupled_pairs(),
        d2 <- delivery_edges(d),
        C.delivery_edge_owner(d, d2) == :order,
        do: refute(C.coupled?(o, d2), "delivery #{d}->#{d2} alone keeps I₈; it needs no owner")
  end

  test "the mirrored step never triggers a further step (no ping-pong)" do
    for {o, d} <- coupled_pairs(),
        o2 <- order_edges(o),
        C.order_edge_owner(o, o2) == :order,
        {:move, d2} <- [C.delivery_effect(d, o, o2)] do
      assert C.order_effect(o2, d, d2) == :none
    end

    for {o, d} <- coupled_pairs(),
        d2 <- delivery_edges(d),
        C.delivery_edge_owner(d, d2) == :delivery,
        {:move, o2} <- [C.order_effect(o, d, d2)] do
      assert C.delivery_effect(d2, o, o2) == :none
    end
  end
end
