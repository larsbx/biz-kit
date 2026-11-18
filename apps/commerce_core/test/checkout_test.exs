defmodule CommerceCore.CheckoutTest do
  @moduledoc """
  Checkout over an arbitrary workflow: the workflow's fulfillments are the only
  ones checkout offers, so every order checkout places is one the lifecycle can
  start. The restaurant instance is pinned against the legacy fixture in
  RestaurantCore.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias CommerceCore.Checkout
  alias OrderCore.Lifecycle, as: OrderLifecycle

  @pool [:delivery, :pickup, :dine_in, :ship, :curbside]

  defp m(n), do: Money.from_integer(n, :USD)

  defp workflow(fulfillments),
    do:
      OrderLifecycle.workflow!(%{
        fulfillments: fulfillments,
        stages: [pack: :packed],
        stage_roles: [:staff]
      })

  defp trusted,
    do: %{merchant: "shop", principal: "ada", cart_id: "c", granted: true, operation: :checkout}

  defp command(fulfillment),
    do: %{
      cart_id: "c",
      channel: :web,
      idempotency_key: "k",
      fulfillment: fulfillment,
      delivery: %{},
      adjustments: %{discount_total: m(0), tax_total: m(0), delivery_fee: m(0), tip: m(0)}
    }

  defp projection(w) do
    lines = [%{unit_price: m(500), quantity: 2, discount: m(0)}]
    cart = %{principal: "ada", status: :active, currency: :USD, lines: lines}
    {:ok, state} = Checkout.new(w, "shop", %{"c" => cart})
    state
  end

  property "checkout offers exactly the workflow's fulfillments, and the lifecycle starts every order it places" do
    check all(
            mask <- integer(1..(2 ** length(@pool) - 1)),
            requested <- member_of([:unknown | @pool])
          ) do
      offered = for {f, i} <- Enum.with_index(@pool), Bitwise.band(mask, 2 ** i) != 0, do: f
      w = workflow(offered)

      case Checkout.apply(projection(w), trusted(), command(requested)) do
        {:ok, _, order, :accepted} ->
          assert requested in offered
          assert order.delivery_request == if(requested == :delivery, do: :required)
          assert {:ok, %{state: :placed}} = OrderLifecycle.new(w, "shop", "o", order.fulfillment)

        {:error, :invalid_fulfillment} ->
          refute requested in offered
          assert OrderLifecycle.new(w, "shop", "o", requested) == {:error, :invalid_order}
      end
    end
  end

  test "delivery still needs its details where it is offered" do
    w = workflow([:delivery, :ship])

    assert Checkout.apply(projection(w), trusted(), Map.delete(command(:delivery), :delivery)) ==
             {:error, :delivery_required}
  end

  test "a projection needs a workflow" do
    for bad <- [nil, %{}, %{fulfillments: []}] do
      assert Checkout.new(bad, "shop", %{}) == {:error, :invalid_checkout_projection}
    end

    assert Checkout.new(workflow([:pickup]), "", %{}) == {:error, :invalid_checkout_projection}
  end
end
