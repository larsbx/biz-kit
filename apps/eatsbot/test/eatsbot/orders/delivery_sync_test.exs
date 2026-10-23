defmodule EatsbotCore.Orders.DeliverySyncTest do
  @moduledoc """
  I₈ against the database: each side's owned edges mirror onto the other in the same
  transaction, and each side refuses the other's edges. The pure proofs are in
  `delivery_coupling_test.exs`.
  """
  use Eatsbot.DataCase, async: true
  use ExUnitProperties

  alias EatsbotCore.Carts.Cart
  alias EatsbotCore.Deliveries.Delivery
  alias EatsbotCore.Orders.{DeliveryCoupling, Order, Transitions}
  alias EatsbotCore.Products.{Option, Product}

  @admin %{access_level: :admin}
  @staff %{access_level: :staff}
  @delivery_input %{
    to_name: "Ada",
    to_address: "1 Main St",
    to_phone: "+12125550123",
    to_latitude: 40.7128,
    to_longitude: -74.006,
    delivery_person: %{}
  }

  setup do
    product =
      Product.create!(
        %{
          name: "Margherita",
          description: "Pizza",
          state: :enabled,
          sku: "M",
          discount_rules: []
        },
        actor: @admin
      )
      |> Product.update_price!(Money.new!(:USD, "12.50"), actor: @admin)

    Option.add_value!(Product.get_or_create_option!(product, "Size", actor: @admin), "L",
      actor: @admin
    )

    variant =
      product
      |> Ash.load!([options: [:option_values]], actor: @admin)
      |> Product.generate_variants!(actor: @admin)
      |> Ash.load!(:variants, actor: @admin)
      |> Map.fetch!(:variants)
      |> hd()

    {:ok, variant: variant}
  end

  defp place_delivery_order(variant) do
    %{order_id: id} =
      Cart.create!(%{currency: "USD"})
      |> Cart.add_variant!(variant.id, 1, "")
      |> Map.fetch!(:id)
      |> Cart.checkout!(:delivery, Ash.UUIDv7.generate(), %{
        contact: %{name: "Ada"},
        delivery: @delivery_input
      })

    reload(id)
  end

  defp reload(order_id),
    do: Ash.get!(Order, order_id, actor: @admin, load: [:delivery, :state_changes])

  defp courier(order), do: %{access_level: :private, delivery_id: order.delivery.id}

  defp move_delivery(order, state),
    do: Delivery.update_state(order.delivery, state, actor: courier(order))

  defp assert_coupled(order) do
    assert DeliveryCoupling.coupled?(order.state, order.delivery.state),
           "order #{order.state} with delivery #{order.delivery.state}"
  end

  describe "the order drives the kitchen" do
    test "accept, preparing and ready move the delivery along", %{variant: v} do
      order = place_delivery_order(v)
      assert order.delivery.state == "Init"

      order = order |> Order.accept!(actor: @staff) |> Map.fetch!(:id) |> reload()
      assert order.delivery.state == "Init"

      order = order |> Order.start_preparing!(actor: @staff) |> Map.fetch!(:id) |> reload()
      assert order.delivery.state == "In_Preparation"

      order = order |> Order.mark_ready!(actor: @staff) |> Map.fetch!(:id) |> reload()
      assert order.delivery.state == "Ready_To_Pickup"
      assert_coupled(order)
    end

    test "cancelling the order aborts its delivery", %{variant: v} do
      order =
        place_delivery_order(v)
        |> Order.accept!(actor: @staff)
        |> Order.start_preparing!(actor: @staff)

      order = order |> Order.cancel!("out of dough", actor: @staff) |> Map.fetch!(:id) |> reload()

      assert order.state == :cancelled
      assert order.delivery.state == "Delivery_Aborted"
    end

    test "the delivery refuses kitchen edges taken directly", %{variant: v} do
      order = place_delivery_order(v)
      assert {:error, _} = move_delivery(order, "In_Preparation")
      assert {:error, _} = move_delivery(order, "Delivery_Aborted")
      assert reload(order.id).delivery.state == "Init"
    end
  end

  describe "the delivery drives dispatch" do
    setup %{variant: v} do
      ready =
        place_delivery_order(v)
        |> Order.accept!(actor: @staff)
        |> Order.start_preparing!(actor: @staff)
        |> Order.mark_ready!(actor: @staff)
        |> Map.fetch!(:id)
        |> reload()

      {:ok, ready: ready}
    end

    test "pickup dispatches the order and drop-off completes it, recorded as system steps",
         %{ready: order} do
      {:ok, _} = move_delivery(order, "In_Delivery")
      order = reload(order.id)
      assert order.state == :dispatched

      {:ok, _} = move_delivery(order, "Delivery_Done")
      order = reload(order.id)
      assert order.state == :completed

      assert [%{to: :dispatched, actor_type: :system}, %{to: :completed, actor_type: :system}] =
               Enum.take(order.state_changes, -2)
    end

    test "a problem keeps the order dispatched; an unresolved one fails it", %{ready: order} do
      {:ok, _} = move_delivery(order, "In_Delivery")
      {:ok, _} = move_delivery(reload(order.id), "Delivery_With_Problems")
      assert reload(order.id).state == :dispatched

      {:ok, _} = move_delivery(reload(order.id), "Stale_Delivery_With_Problems")
      assert reload(order.id).state == :failed
    end

    test "the order refuses dispatch edges taken directly, even by an admin", %{ready: order} do
      assert {:error, _} = Order.dispatch(order, actor: @admin)
      {:ok, _} = move_delivery(order, "In_Delivery")
      order = reload(order.id)
      assert {:error, _} = Order.complete(order, actor: @admin)
      assert {:error, _} = Order.fail(order, "lost", actor: @admin)
      assert reload(order.id).state == :dispatched
    end
  end

  test "a delivery step whose mirror the order refuses is rolled back with it", %{variant: v} do
    # done_with_distance_check forces Delivery_With_Problems from any state; from Init that
    # would dispatch a placed order, which δ forbids, so neither side may change.
    order = place_delivery_order(v)
    assert {:error, _} = Delivery.done_with_distance_check(order.delivery, actor: courier(order))

    order = reload(order.id)
    assert {order.state, order.delivery.state} == {:placed, "Init"}
    assert order.state_changes == []
  end

  test "an order step whose delivery mirror is refused is rolled back with it", %{variant: v} do
    # Desync behind Ash's back, so the kitchen's mirror (Init → In_Preparation) is illegal.
    order = place_delivery_order(v) |> Order.accept!(actor: @staff)

    Eatsbot.Repo.query!("UPDATE deliveries SET state = 'Delivery_Done' WHERE order_id = $1", [
      Ecto.UUID.dump!(order.id)
    ])

    assert {:error, _} = Order.start_preparing(order, actor: @staff)
    order = reload(order.id)
    assert {order.state, length(order.state_changes)} == {:accepted, 1}
  end

  test "no Delivery update action except update_state accepts state" do
    # Every write of a delivery's state passes the transition guard and the order sync.
    for %{type: :update, name: name, accept: accept} <- Ash.Resource.Info.actions(Delivery),
        :state in accept do
      assert name == :update_state, "#{name} accepts :state"
    end
  end

  test "a delivery without an order keeps its old behaviour" do
    delivery = Delivery.empty!(actor: @admin)

    assert {:ok, %{state: "In_Preparation"}} =
             Delivery.update_state(delivery, "In_Preparation", actor: @admin)
  end

  property "I₈ holds after any interleaving of order and delivery steps", %{variant: v} do
    steps = [
      {:order, &Order.accept(&1, actor: @staff)},
      {:order, &Order.start_preparing(&1, actor: @staff)},
      {:order, &Order.mark_ready(&1, actor: @staff)},
      {:order, &Order.cancel(&1, "test", actor: @staff)},
      {:order, &Order.dispatch(&1, actor: @admin)},
      {:order, &Order.complete(&1, actor: @admin)}
      | for(
          s <- ~w(In_Preparation Ready_To_Pickup In_Delivery Delivery_With_Problems Delivery_Done
                    Delivery_Aborted Stale_Delivery_With_Problems Stale_Delivery_Done),
          do: {:delivery, &move_delivery(&1, s)}
        )
    ]

    check all(picks <- list_of(member_of(steps), max_length: 10), max_runs: 40) do
      final =
        Enum.reduce(picks, place_delivery_order(v), fn {_side, step}, order ->
          _ = step.(order)
          order = reload(order.id)
          assert_coupled(order)
          order
        end)

      history = for %{from: f, to: t} <- final.state_changes, do: {f, t}
      assert Transitions.replay(:delivery, history) == {:ok, final.state}
    end
  end
end
