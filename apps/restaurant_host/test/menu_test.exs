defmodule RestaurantHost.MenuTest do
  @moduledoc """
  The menu on the Log (decommission D6). The refinement this rests on: every
  item `RestaurantCore.Menu` admits converts to a catalog product, with rules
  `CommerceCore.Discounts` accepts, so an admitted edit always reaches the
  storefront. And the storefront shows an admitted edit without a restart.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias CommerceCore.{Catalog, Discounts}
  alias RestaurantHost.{Menu, Orders, World}

  @endpoint RestaurantHost.Web.Endpoint

  defp rule_gen do
    fixed = %{
      "percent_off" => map(member_of(~w(0.1 0.15 1 1.0 0.000001 0.5)), &%{"rate" => &1}),
      "unit_price" => map(integer(-5..5000), &%{"price_minor" => &1}),
      "buy_x_pay_y" =>
        map({integer(0..6), integer(0..6)}, fn {x, y} -> %{"x" => x, "y" => y} end),
      "x_for_amount" =>
        map({integer(0..6), integer(-5..9000)}, fn {x, a} -> %{"x" => x, "amount_minor" => a} end)
    }

    bind(member_of(Map.keys(fixed)), fn method ->
      map(
        {fixed[method], boolean(), list_of(integer(0..8), max_length: 3),
         list_of(integer(-1..24), length: 2), integer(0..3)},
        fn {fields, on, days, hours, minq} ->
          fields
          |> Map.merge(%{"method" => method, "enabled" => on, "min_quantity" => minq})
          |> then(&if days == [], do: &1, else: Map.put(&1, "weekdays", days))
          |> Map.put("hours", hours)
        end
      )
    end)
  end

  defp item_gen do
    map(
      {integer(-1..3000), list_of(rule_gen(), max_length: 3), member_of(~w(published hidden))},
      fn
        {price, rules, vis} ->
          rules =
            rules |> Enum.with_index() |> Enum.map(fn {r, i} -> Map.put(r, "id", "r#{i}") end)

          World.item("pizza", "Pizza", "PIZ", price, rules) |> Map.put("visibility", vis)
      end
    )
  end

  property "every admitted item converts to a catalog product the storefront accepts" do
    check all(wire <- item_gen(), max_runs: 300) do
      case RestaurantCore.Menu.decode_item(wire) do
        {:ok, item} ->
          for r <- item.discounts,
              do: assert({:ok, _} = Discounts.normalize(Menu.discount(r, :USD)))

          %{catalog: catalog} = Menu.from(%{items: %{"pizza" => item}}, "shop", :USD)
          assert {:ok, _} = Catalog.fetch(catalog, "shop", "pizza")

        {:error, :invalid_menu_item} ->
          :ok
      end
    end
  end

  test "an admitted edit is on the storefront without a restart; hidden items leave it" do
    w = World.build()
    {:ok, store, html} = live(build_conn(), "/")
    refute html =~ "Calzone"

    World.put_item!(w.chapter, w.governance, World.item("calzone", "Calzone", "CALZ", 1500), 2)
    assert render(store) =~ "Calzone"
    assert Enum.map(Orders.menu(w.restaurant), & &1.id) == ~w(calzone margherita pepperoni)

    hidden = World.item("calzone", "Calzone", "CALZ", 1500) |> Map.put("visibility", "hidden")
    World.put_item!(w.chapter, w.governance, hidden, 3)
    refute render(store) =~ "Calzone"
    assert Orders.price(w.restaurant, %{"calzone" => 1}) == {:error, :unknown_item}
  end

  test "an order keeps the price it was placed at" do
    w = World.build()
    {:ok, id} = Orders.place(w.restaurant, %{"margherita" => 1}, "Ada", "k-1")

    World.put_item!(
      w.chapter,
      w.governance,
      World.item("margherita", "Margherita", "MARG", 2000),
      2
    )

    assert {:ok, %{total: total}} = Orders.price(w.restaurant, %{"margherita" => 1})
    assert Money.to_integer_exp(total) |> elem(1) == 2120
    # 12.50 + Michigan's 6% (0.75)
    assert %{total: 1325} = Orders.get(w.restaurant, id)
  end
end
