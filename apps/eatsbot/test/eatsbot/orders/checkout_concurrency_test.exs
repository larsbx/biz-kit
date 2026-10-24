defmodule EatsbotCore.Orders.CheckoutConcurrencyTest do
  @moduledoc """
  I₅ under real concurrency: copies of one checkout racing each other must all get the
  same order. The SQL sandbox serializes everything onto one connection, so this runs
  on real connections and real transactions, and cleans up after itself. ExUnit runs
  synchronous modules after the asynchronous ones, so nothing else is using the tables.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Eatsbot.Repo
  alias EatsbotCore.Carts.Cart
  alias EatsbotCore.Products.{Option, Product}

  @admin %{access_level: :admin}
  @copies 8

  setup do
    Sandbox.mode(Repo, :auto)

    on_exit(fn ->
      Repo.query!("""
      TRUNCATE orders, order_lines, order_state_changes, deliveries, delivery_state_changes,
               cart_lines, carts, variant_option, prices, variants, option_values,
               product_option, options, products CASCADE
      """)
    end)

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

    [variant | _] =
      product
      |> Ash.load!([options: [:option_values]], actor: @admin)
      |> Product.generate_variants!(actor: @admin)
      |> Ash.load!(:variants, actor: @admin)
      |> Map.fetch!(:variants)

    {:ok, cart: Cart.create!(%{currency: "USD"}) |> Cart.add_variant!(variant.id, 1, "")}
  end

  test "concurrent copies of one checkout all return the same order", %{cart: cart} do
    results =
      1..@copies
      |> Task.async_stream(
        fn _ -> Cart.checkout(cart.id, :pickup, "same-key", %{contact: %{name: "Ada"}}) end,
        max_concurrency: @copies,
        timeout: 15_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert [{:ok, %{order_id: _}} = first] = Enum.uniq(results),
           "expected one shared result, got: #{inspect(Enum.uniq(results), pretty: true)}"

    assert {:ok, %{order_id: id}} = first
    assert %{rows: [[1]]} = Repo.query!("SELECT count(*) FROM orders")
    assert is_binary(id)
  end
end
