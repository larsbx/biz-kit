defmodule EatsbotCore.Orders.OrderTest do
  @moduledoc """
  Acceptance criteria and invariants I₁–I₆ of spec epic E0.1, against the database.
  """
  use Eatsbot.DataCase, async: true
  use ExUnitProperties

  alias EatsbotCore.Carts.Cart
  alias EatsbotCore.Orders.{Order, OrderLine, OrderStateChange, Pricing, Transitions}
  alias EatsbotCore.Products.{Option, Product}

  @admin %{access_level: :admin}
  @system %{access_level: :system}
  @stranger %{}

  @contact %{name: "Ada", phone: "+12125550123"}
  @delivery %{
    to_name: "Ada",
    to_address: "1 Main St",
    to_phone: "+12125550123",
    to_latitude: 40.7128,
    to_longitude: -74.006,
    delivery_person: %{}
  }

  setup do
    {:ok, variants: variants([{"Margherita", "12.50"}, {"Pepperoni", "14.00"}])}
  end

  defp variants(specs) do
    for {name, amount} <- specs do
      product =
        Product.create!(
          %{name: name, description: name, state: :enabled, sku: name, discount_rules: []},
          actor: @admin
        )
        |> Product.update_price!(Money.new!(:USD, amount), actor: @admin)

      option = Product.get_or_create_option!(product, "Size", actor: @admin)
      Option.add_value!(option, "Large", actor: @admin)

      product
      |> Ash.load!([options: [:option_values]], actor: @admin)
      |> Product.generate_variants!(actor: @admin)
      |> Ash.load!([variants: [:prices]], actor: @admin)
      |> Map.fetch!(:variants)
      |> hd()
    end
  end

  defp cart_with(variants) do
    Enum.reduce(variants, Cart.create!(%{currency: "USD"}), fn {variant, qty}, cart ->
      Cart.add_variant!(cart, variant.id, qty, "")
    end)
  end

  defp checkout!(cart, fulfillment, key, extra \\ %{}),
    do: Cart.checkout!(cart.id, fulfillment, key, Map.merge(%{contact: @contact}, extra))

  defp order!(%{order_id: id}),
    do: Ash.get!(Order, id, actor: @admin, load: [:lines, :state_changes, :delivery])

  describe "checkout (E0.1 acceptance)" do
    test "copies each line's price into the order, and later price changes don't reach it",
         %{variants: [margherita, pepperoni]} do
      cart = cart_with([{margherita, 2}, {pepperoni, 1}])
      order = cart |> checkout!(:pickup, "k-1") |> order!()

      assert order.state == :placed
      assert order.currency == "USD"
      assert length(order.lines) == 2

      by_name = Map.new(order.lines, &{&1.name, &1})
      assert Money.equal?(by_name[margherita.name].unit_price, Money.new!(:USD, "12.50"))
      assert by_name[margherita.name].quantity == 2
      assert Money.equal?(by_name[pepperoni.name].unit_price, Money.new!(:USD, "14.00"))
      assert Money.equal?(order.subtotal, Money.new!(:USD, "39.00"))
      assert Money.equal?(order.total, Money.new!(:USD, "39.00"))

      for price <- margherita.prices,
          do: Ash.update!(price, %{money: Money.new!(:USD, "99.00")}, actor: @admin)

      reloaded = order!(%{order_id: order.id})

      assert Money.equal?(
               Map.new(reloaded.lines, &{&1.name, &1})[margherita.name].unit_price,
               Money.new!(:USD, "12.50")
             )

      assert Money.equal?(reloaded.total, order.total)
    end

    test "completes the cart, and checkout is idempotent per key", %{variants: [v | _]} do
      cart = cart_with([{v, 1}])
      first = checkout!(cart, :pickup, "k-1")

      assert Ash.get!(Cart, cart.id).status == :completed
      assert checkout!(cart, :pickup, "k-1").order_id == first.order_id

      assert {:error, error} = Cart.checkout(cart.id, :pickup, "k-2", %{contact: @contact})
      assert Exception.message(error) =~ "cart is not active"
    end

    test "a retried delivery checkout returns the same delivery key", %{variants: [v | _]} do
      cart = cart_with([{v, 1}])
      first = checkout!(cart, :delivery, "k-1", %{delivery: @delivery})

      assert first.delivery_key
      assert checkout!(cart, :delivery, "k-1", %{delivery: @delivery}) == first
    end

    test "an idempotency key can't be reused for another cart", %{variants: [v | _]} do
      _first = cart_with([{v, 1}]) |> checkout!(:pickup, "k-1")
      other = cart_with([{v, 1}])

      assert {:error, error} = Cart.checkout(other.id, :pickup, "k-1", %{contact: @contact})
      assert Exception.message(error) =~ "already used for another cart"
      assert Ash.get!(Cart, other.id).status == :active
    end

    test "tip and delivery fee are added to the total (I₂)", %{variants: [v | _]} do
      order =
        cart_with([{v, 1}])
        |> checkout!(:delivery, "k-1", %{
          delivery: @delivery,
          tip: Money.new!(:USD, "2.00"),
          delivery_fee: Money.new!(:USD, "3.00")
        })
        |> order!()

      assert Money.equal?(order.total, Money.new!(:USD, "17.50"))
    end

    test "I₄: a delivery order gets exactly one Delivery, other fulfillments none", %{
      variants: [v | _]
    } do
      delivery_order = cart_with([{v, 1}]) |> checkout!(:delivery, "k-1", %{delivery: @delivery})
      assert %{delivery: %{order_id: id}} = order!(delivery_order)
      assert id == delivery_order.order_id
      assert EatsbotCore.Deliveries.Delivery.get_via_token!(delivery_order.delivery_key)

      pickup_order = cart_with([{v, 1}]) |> checkout!(:pickup, "k-2")
      assert order!(pickup_order).delivery == nil
      assert pickup_order.delivery_key == nil
    end

    test "a delivery order without an address is rejected and changes nothing", %{
      variants: [v | _]
    } do
      cart = cart_with([{v, 1}])
      assert {:error, _} = Cart.checkout(cart.id, :delivery, "k-1", %{contact: @contact})
      assert Ash.get!(Cart, cart.id).status == :active
      assert Ash.read!(Order, actor: @admin) == []
    end

    test "the legacy cartCheckoutDelivery path still returns a tracking key", %{variants: [v | _]} do
      cart = cart_with([{v, 1}])
      token = Cart.checkout_delivery!(cart.id, Map.put(@delivery, :delivery_order, %{}))
      assert EatsbotCore.Deliveries.Delivery.get_via_token!(token)
      assert [%Order{fulfillment: :delivery}] = Ash.read!(Order, actor: @admin)
    end
  end

  describe "transitions (I₃, I₆)" do
    setup %{variants: [v | _]} do
      {:ok, order: cart_with([{v, 1}]) |> checkout!(:pickup, "k-1") |> order!()}
    end

    test "a pickup order runs placed → completed and records every step", %{order: order} do
      done =
        order
        |> Order.accept!(actor: @admin)
        |> Order.start_preparing!(actor: @admin)
        |> Order.mark_ready!(actor: @admin)
        |> Order.complete!(actor: @admin)

      assert done.state == :completed
      history = history(done)

      assert history == [
               {:placed, :accepted},
               {:accepted, :preparing},
               {:preparing, :ready},
               {:ready, :completed}
             ]

      assert Transitions.replay(:pickup, history) == {:ok, :completed}
    end

    test "an illegal transition fails and writes nothing", %{order: order} do
      assert {:error, %Ash.Error.Invalid{}} = Order.mark_ready(order, actor: @admin)
      assert {:error, %Ash.Error.Invalid{}} = Order.dispatch(order, actor: @system)

      reloaded = order!(%{order_id: order.id})
      assert reloaded.state == :placed
      assert history(reloaded) == []
    end

    test "terminal states are absorbing", %{order: order} do
      cancelled = Order.cancel!(order, "customer called", actor: @admin)
      assert cancelled.state == :cancelled
      assert [%{reason: "customer called"}] = load_changes(cancelled)
      assert {:error, _} = Order.accept(cancelled, actor: @admin)
    end

    property "any sequence of attempted transitions keeps state = replay(history)",
             %{variants: [v | _]} do
      check all(
              fulfillment <- member_of(Transitions.fulfillments()),
              attempts <- list_of(member_of(transition_actions()), max_length: 8),
              max_runs: 40
            ) do
        extra = if fulfillment == :delivery, do: %{delivery: @delivery}, else: %{}

        order =
          cart_with([{v, 1}]) |> checkout!(fulfillment, Ash.UUIDv7.generate(), extra) |> order!()

        final =
          Enum.reduce(attempts, order, fn action, current ->
            case apply_transition(current, action) do
              {:ok, next} -> next
              {:error, _} -> current
            end
          end)

        reloaded = order!(%{order_id: final.id})
        assert Transitions.replay(fulfillment, history(reloaded)) == {:ok, reloaded.state}

        assert Enum.map(load_changes(reloaded), & &1.sequence) |> Enum.sort() ==
                 Enum.to_list(1..length(history(reloaded))//1)
      end
    end
  end

  describe "I₁: lines and amounts cannot be changed after placement" do
    test "OrderLine and OrderStateChange expose no update or destroy action" do
      for resource <- [OrderLine, OrderStateChange] do
        types = resource |> Ash.Resource.Info.actions() |> Enum.map(& &1.type) |> Enum.uniq()
        refute :update in types, "#{inspect(resource)} has an update action"
        refute :destroy in types, "#{inspect(resource)} has a destroy action"
      end
    end

    test "no Order update action accepts an attribute" do
      for %{type: :update} = action <- Ash.Resource.Info.actions(Order) do
        assert action.accept == [], "#{action.name} accepts #{inspect(action.accept)}"
      end
    end

    test "stored amounts satisfy I₂ against Pricing", %{variants: [a, b]} do
      order =
        cart_with([{a, 3}, {b, 2}])
        |> checkout!(:pickup, "k-1", %{tip: Money.new!(:USD, "5.00")})
        |> order!()

      lines = Enum.map(order.lines, &Map.take(&1, [:unit_price, :quantity, :discount]))

      {:ok, priced} =
        Pricing.price(
          :USD,
          lines,
          Map.take(order, [:discount_total, :tax_total, :delivery_fee, :tip])
        )

      assert Money.equal?(priced.subtotal, order.subtotal)
      assert Money.equal?(priced.total, order.total)
    end
  end

  describe "policies" do
    setup %{variants: [v | _]} do
      {:ok, placed: cart_with([{v, 1}]) |> checkout!(:pickup, "k-1")}
    end

    test "a stranger can neither read nor move an order", %{placed: placed} do
      order = order!(placed)
      assert {:error, %Ash.Error.Forbidden{}} = Order.accept(order, actor: @stranger)
      assert {:error, _} = Ash.get(Order, order.id, actor: @stranger)
    end

    test "the system actor cannot run kitchen transitions", %{placed: placed} do
      assert {:error, %Ash.Error.Forbidden{}} = Order.accept(order!(placed), actor: @system)
    end

    test "anyone holding the tracking key can track the order, and only that order", %{
      placed: placed
    } do
      assert {:ok, %Order{id: id, state: :placed}} = Order.track(placed.tracking_key)
      assert id == placed.order_id
      assert {:error, _} = Order.track(Ash.UUIDv7.generate())
    end
  end

  defp transition_actions,
    do: ~w(accept start_preparing mark_ready dispatch complete fail cancel)a

  defp apply_transition(order, :cancel), do: Order.cancel(order, "test", actor: @admin)
  defp apply_transition(order, :fail), do: Order.fail(order, "test", actor: @admin)
  defp apply_transition(order, action), do: apply(Order, action, [order, [actor: @admin]])

  defp load_changes(order),
    do: order |> Ash.load!(:state_changes, actor: @admin) |> Map.fetch!(:state_changes)

  defp history(order),
    do: order |> load_changes() |> Enum.sort_by(& &1.sequence) |> Enum.map(&{&1.from, &1.to})
end
