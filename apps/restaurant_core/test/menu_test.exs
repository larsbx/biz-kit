defmodule RestaurantCore.MenuTest do
  @moduledoc """
  The restaurant's menu as signed facts (Eatsbot decommission D6): one item at
  a time, at the menu's expected version, money-free, refusing exactly what the
  catalog would refuse so an admitted edit always applies.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias RestaurantCore.Menu

  defp item(extra \\ %{}),
    do:
      Map.merge(
        %{
          "item_id" => "margherita",
          "name" => "Margherita",
          "sku" => "MARG",
          "price_minor" => 1250,
          "currency" => "USD",
          "visibility" => "published",
          "discounts" => []
        },
        extra
      )

  defp rule(extra), do: Map.merge(%{"id" => "r"}, extra)

  describe "decode_item/1" do
    test "a well-formed item decodes, with its discount rules" do
      lunch = rule(%{"method" => "percent_off", "rate" => "0.2", "hours" => [11, 14]})

      assert {:ok, i} = Menu.decode_item(item(%{"discounts" => [lunch]}))
      assert %{id: "margherita", sku: "MARG", price_minor: 1250, currency: "USD"} = i
      assert i.visibility == :published

      assert [%{id: "r", method: :percent_off, rate: "0.2", hours: {11, 14}, weekdays: :any}] =
               i.discounts
    end

    test "refuses what the catalog would refuse" do
      for bad <- [
            item(%{"price_minor" => 0}),
            item(%{"price_minor" => "12.50"}),
            item(%{"sku" => ""}),
            item(%{"item_id" => "bad id"}),
            item(%{"name" => ""}),
            item(%{"currency" => "usd"}),
            item(%{"visibility" => "deleted"}),
            item(%{"discounts" => :none}),
            item(%{"colour" => "red"}),
            Map.delete(item(), "sku")
          ] do
        assert Menu.decode_item(bad) == {:error, :invalid_menu_item}, inspect(bad)
      end
    end
  end

  describe "decode_rule/1" do
    test "each method with its fields and the default conditions" do
      for {r, method} <- [
            {rule(%{"method" => "percent_off", "rate" => "1"}), :percent_off},
            {rule(%{"method" => "unit_price", "price_minor" => 0}), :unit_price},
            {rule(%{"method" => "buy_x_pay_y", "x" => 3, "y" => 2}), :buy_x_pay_y},
            {rule(%{"method" => "x_for_amount", "x" => 2, "amount_minor" => 1}), :x_for_amount}
          ] do
        assert {:ok, %{method: ^method, enabled: true, min_quantity: 1}} = Menu.decode_rule(r)
      end
    end

    test "refuses malformed rules" do
      for r <- [
            rule(%{"method" => "percent_off", "rate" => "0"}),
            rule(%{"method" => "percent_off", "rate" => "0.000"}),
            rule(%{"method" => "percent_off", "rate" => "1.01"}),
            rule(%{"method" => "percent_off", "rate" => 0.5}),
            rule(%{"method" => "percent_off", "rate" => "0.1234567"}),
            rule(%{"method" => "unit_price", "price_minor" => -1}),
            rule(%{"method" => "buy_x_pay_y", "x" => 2, "y" => 2}),
            rule(%{"method" => "x_for_amount", "x" => 1, "amount_minor" => 5}),
            rule(%{"method" => "x_for_amount", "x" => 2, "amount_minor" => 0}),
            rule(%{"method" => "percent_off", "rate" => "0.1", "weekdays" => []}),
            rule(%{"method" => "percent_off", "rate" => "0.1", "weekdays" => [8]}),
            rule(%{"method" => "percent_off", "rate" => "0.1", "hours" => [9, 24]}),
            rule(%{"method" => "percent_off", "rate" => "0.1", "hours" => [9]}),
            rule(%{"method" => "percent_off", "rate" => "0.1", "min_quantity" => 0}),
            rule(%{"method" => "percent_off", "rate" => "0.1", "enabled" => "yes"}),
            rule(%{"method" => "percent_off", "rate" => "0.1", "x" => 2}),
            rule(%{"method" => "fixed", "discount" => 5}),
            %{"method" => "percent_off", "rate" => "0.1"}
          ] do
        assert Menu.decode_rule(r) == {:error, :invalid_discount}, inspect(r)
      end
    end

    test "rule ids within an item are distinct" do
      r = rule(%{"method" => "percent_off", "rate" => "0.1"})
      assert Menu.decode_item(item(%{"discounts" => [r, r]})) == {:error, :invalid_menu_item}
    end
  end

  describe "put/3" do
    test "versions advance by one; a stale version or another item's SKU is refused" do
      {:ok, a} = Menu.decode_item(item())
      {:ok, b} = Menu.decode_item(item(%{"item_id" => "pepperoni", "sku" => "PEPP"}))

      assert {:ok, m1} = Menu.put(Menu.new(), 0, a)
      assert m1.version == 1
      assert Menu.put(m1, 0, b) == {:error, :stale_menu_version}
      assert {:ok, m2} = Menu.put(m1, 1, b)
      assert Map.keys(m2.items) |> Enum.sort() == ["margherita", "pepperoni"]

      {:ok, clash} = Menu.decode_item(item(%{"item_id" => "pepperoni", "sku" => "MARG"}))
      assert Menu.put(m2, 2, clash) == {:error, :duplicate_sku}

      {:ok, repriced} = Menu.decode_item(item(%{"price_minor" => 1300}))

      assert {:ok, %{version: 3, items: %{"margherita" => %{price_minor: 1300}}}} =
               Menu.put(m2, 2, repriced)
    end
  end

  property "encode_item is the inverse of decode_item on every admitted item" do
    rule =
      fixed_map(%{
        "id" => constant("r"),
        "method" => constant("percent_off"),
        "rate" => member_of(~w(0.1 0.25 1 0.000001)),
        "enabled" => boolean(),
        "min_quantity" => integer(1..3)
      })
      |> bind(fn r ->
        one_of([
          constant(r),
          map(integer(0..23), &Map.put(r, "hours", [&1, rem(&1 + 5, 24)])),
          map(list_of(integer(1..7), min_length: 1), &Map.put(r, "weekdays", Enum.uniq(&1)))
        ])
      end)

    other =
      one_of([
        map(integer(0..900), &%{"id" => "u", "method" => "unit_price", "price_minor" => &1}),
        constant(%{"id" => "b", "method" => "buy_x_pay_y", "x" => 3, "y" => 2}),
        constant(%{"id" => "x", "method" => "x_for_amount", "x" => 2, "amount_minor" => 900})
      ])

    check all(
            listed <- list_of(one_of([rule, other]), max_length: 3),
            rules =
              listed |> Enum.with_index() |> Enum.map(fn {r, i} -> %{r | "id" => "r#{i}"} end),
            price <- integer(1..5000),
            vis <- member_of(~w(published hidden))
          ) do
      {:ok, i} =
        Menu.decode_item(
          item(%{"discounts" => rules, "price_minor" => price, "visibility" => vis})
        )

      assert Menu.decode_item(Menu.encode_item(i)) == {:ok, i}
    end
  end
end
