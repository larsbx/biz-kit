defmodule CommerceCore.HomeIsolationTest do
  use ExUnit.Case, async: true

  alias CommerceCore.{Catalog, Checkout, OrderLifecycle}

  @a %{home_id: "home-a", merchant: "shop"}
  @b %{home_id: "home-b", merchant: "shop"}
  @other %{home_id: "home-a", merchant: "other-shop"}

  defp m(n), do: Money.from_integer(n, :USD)

  defp product(id, variant) do
    %{
      id: id,
      sku: id,
      visibility: :published,
      prices: %{USD: m(100)},
      variants: [%{id: variant, sku: variant, prices: %{USD: m(200)}}]
    }
  end

  defp cart(owner, principal \\ "ada") do
    Map.merge(owner, %{
      principal: principal,
      status: :active,
      currency: :USD,
      lines: [%{name: "meal", unit_price: m(100), quantity: 1, discount: m(0)}]
    })
  end

  defp grant(owner, operation \\ :checkout) do
    Map.merge(owner, %{principal: "ada", granted: true, operation: operation, cart_id: "cart"})
  end

  defp command do
    %{
      cart_id: "cart",
      channel: :web,
      idempotency_key: "same-key",
      fulfillment: :pickup,
      adjustments: %{discount_total: m(0), tax_total: m(0), delivery_fee: m(0), tip: m(0)}
    }
  end

  test "catalog reads, writes and prices require home AND merchant before identifier lookup" do
    {:ok, a} = Catalog.new(@a)
    {:ok, a} = Catalog.put(a, @a, 0, product("meal-a", "large-a"))
    {:ok, b} = Catalog.new(@b)
    {:ok, b} = Catalog.put(b, @b, 0, product("meal-b", "large-b"))

    for foreign <- [@b, @other, "shop", %{}, nil] do
      for id <- ["meal-a", "meal-b", "missing"] do
        assert Catalog.fetch(a, foreign, id) == {:error, :forbidden}
        assert Catalog.quote(a, foreign, id, "large-a", :USD) == {:error, :forbidden}
      end

      assert Catalog.put(a, foreign, 1, product("new", "new-large")) == {:error, :forbidden}
    end

    assert {:ok, %{id: "meal-a"}} = Catalog.fetch(a, @a, "meal-a")
    assert Catalog.fetch(a, @a, "meal-b") == {:error, :unknown_product}
    assert Catalog.quote(a, @a, "meal-a", "large-b", :USD) == {:error, :unknown_variant}

    assert {:ok, %{home_id: "home-a", merchant: "shop", unit_price: price}} =
             Catalog.quote(a, @a, "meal-a", "large-a", :USD)

    assert Money.equal?(price, m(200))
    assert {:ok, %{home_id: "home-b"}} = Catalog.quote(b, @b, "meal-b", nil, :USD)
  end

  test "cart access and checkout refuse foreign scope, identifiers and principal without history" do
    {:ok, a} = Checkout.new(@a, %{"cart" => cart(@a), "private" => cart(@a, "grace")})

    for owner <- [@b, @other] do
      for id <- ["cart", "private", "missing"] do
        assert Checkout.fetch_cart(a, %{grant(owner, :cart_read) | cart_id: id}, id) ==
                 {:error, :forbidden}

        assert Checkout.apply(a, %{grant(owner) | cart_id: id}, %{command() | cart_id: id}) ==
                 {:error, :forbidden}
      end
    end

    assert Checkout.fetch_cart(a, grant(@a, :cart_read), "private") == {:error, :forbidden}

    assert Checkout.fetch_cart(a, %{grant(@a, :cart_read) | cart_id: "private"}, "private") ==
             {:error, :forbidden}

    assert Checkout.fetch_cart(a, grant(@a), "cart") == {:error, :forbidden}
    assert {:ok, %{principal: "ada"}} = Checkout.fetch_cart(a, grant(@a, :cart_read), "cart")
    assert Checkout.apply(a, Map.delete(grant(@a), :home_id), command()) == {:error, :forbidden}
    assert Checkout.apply(a, %{grant(@a) | granted: false}, command()) == {:error, :forbidden}
  end

  test "identical idempotency keys are independent across homes and merchants; repeats reauthorize" do
    for owner <- [@a, @b, @other] do
      {:ok, state} = Checkout.new(owner, %{"cart" => cart(owner), "second" => cart(owner)})
      assert {:ok, placed, order, :accepted} = Checkout.apply(state, grant(owner), command())
      assert order.home_id == owner.home_id
      assert order.merchant == owner.merchant
      assert order.financial_status == :unconfirmed
      assert {:ok, ^placed, ^order, :duplicate} = Checkout.apply(placed, grant(owner), command())

      assert Checkout.apply(placed, %{grant(owner) | granted: false}, command()) ==
               {:error, :forbidden}

      assert Checkout.apply(placed, %{grant(owner) | principal: "mallory"}, command()) ==
               {:error, :forbidden}

      assert Checkout.apply(placed, %{grant(owner) | cart_id: "second"}, %{
               command()
               | cart_id: "second"
             }) ==
               {:error, :idempotency_conflict}

      assert placed.carts["second"].status == :active
      assert map_size(placed.orders) == 1
    end
  end

  test "foreign persisted cart or order snapshots cannot be relabeled or returned on retry" do
    assert Checkout.new(@a, %{"cart" => cart(@b)}) == {:error, :invalid_checkout_projection}

    assert Checkout.new(@a, %{"cart" => Map.delete(cart(@a), :home_id)}) ==
             {:error, :invalid_checkout_projection}

    assert Checkout.new(@a, %{"cart" => nil}) == {:error, :invalid_checkout_projection}

    {:ok, state} = Checkout.new(@a, %{"cart" => cart(@a)})
    {:ok, placed, order, :accepted} = Checkout.apply(state, grant(@a), command())
    contaminated = put_in(placed.orders[{:web, "same-key"}], %{order | home_id: "home-b"})
    assert Checkout.apply(contaminated, grant(@a), command()) == {:error, :forbidden}
    contaminated = put_in(state.carts["cart"], cart(@other))
    assert Checkout.apply(contaminated, grant(@a), command()) == {:error, :forbidden}

    assert Checkout.fetch_cart(contaminated, grant(@a, :cart_read), "cart") ==
             {:error, :forbidden}
  end

  test "order commands and duplicate command IDs cannot cross a home or merchant" do
    {:ok, state} = OrderLifecycle.new(@a, "order", :pickup)

    trusted =
      Map.merge(@a, %{
        granted: true,
        principal: "ada",
        actor: :staff,
        order_id: "order",
        allowed_actions: [:accept]
      })

    cmd = %{id: "command", action: :accept, expected_version: 0}
    assert {:ok, accepted, :accepted} = OrderLifecycle.apply(state, trusted, cmd)
    assert {:ok, ^accepted, :duplicate} = OrderLifecycle.apply(accepted, trusted, cmd)

    for ctx <- [
          Map.merge(trusted, @b),
          Map.merge(trusted, @other),
          Map.delete(trusted, :home_id),
          %{trusted | order_id: "foreign"},
          %{trusted | granted: false}
        ] do
      assert OrderLifecycle.apply(accepted, ctx, cmd) == {:error, :forbidden}
    end
  end

  test "merchant-only compatibility state cannot silently accept a home grant" do
    {:ok, old} = Checkout.new("shop", %{"cart" => cart(@a)})
    assert Checkout.apply(old, grant(@a), command()) == {:error, :forbidden}
  end
end
