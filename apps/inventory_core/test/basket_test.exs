defmodule InventoryCore.BasketTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias InventoryCore.Basket

  defp stocked(merchant, item, unit, available) do
    {:ok, empty} = InventoryCore.new(merchant, item, unit)

    {:ok, filled, :accepted} =
      InventoryCore.apply(empty, merchant, %{
        id: "receipt-" <> item,
        expected_version: 0,
        op: :receive,
        location: "kitchen",
        quantity: available
      })

    filled
  end

  defp ingredients do
    [
      %{item: "cheese", unit: "grams", per_unit: 80},
      %{item: "dough", unit: "grams", per_unit: 120}
    ]
  end

  defp stock do
    %{
      "cheese" => stocked("restaurant", "cheese", "grams", 1000),
      "dough" => stocked("restaurant", "dough", "grams", 1500)
    }
  end

  test "restaurant ingredient basket proposes every hold without mutating stock" do
    original = stock()

    assert {:ok, candidate} =
             Basket.plan(original, "restaurant", "kitchen", "pizza-order-1", 3, ingredients(), 2000)

    assert candidate.kind == :unsigned_inventory_basket
    assert candidate.merchant == "restaurant"
    assert Enum.map(candidate.commands, & &1.item) == ["cheese", "dough"]
    assert Enum.map(candidate.commands, & &1.command.quantity) == [240, 360]
    assert Enum.all?(candidate.commands, &(&1.command.expected_version == 1))
    assert Enum.all?(candidate.commands, &(&1.command.id == "pizza-order-1"))
    assert original == stock()
    assert Enum.all?(Map.values(original), &(map_size(&1.reservations) == 0))
  end

  test "failed later ingredient never produces a partial successful basket" do
    original = %{stock() | "dough" => stocked("restaurant", "dough", "grams", 100)}

    assert {:error, {"dough", :insufficient_available}} =
             Basket.plan(original, "restaurant", "kitchen", "pizza-order-2", 1, ingredients(), 2000)

    assert {:ok, 1000} =
             InventoryCore.available(original["cheese"], "restaurant", "kitchen")

    assert original["cheese"].reservations == %{}
    assert original["dough"].reservations == %{}
  end

  test "menu sellable ceiling matches all-ingredient reservation feasibility" do
    original = stock()

    recipe =
      Enum.map(ingredients(), fn %{item: item, per_unit: amount} ->
        %{item: item, quantity: amount}
      end)

    assert {:ok, 12} = InventoryCore.Menu.sellable(recipe, original, "restaurant", "kitchen")

    assert {:ok, %{commands: [_cheese, _dough]}} =
             Basket.plan(original, "restaurant", "kitchen", "max-sellable", 12, ingredients(), 500)

    assert {:error, {"cheese", :insufficient_available}} =
             Basket.plan(original, "restaurant", "kitchen", "over-sellable", 13, ingredients(), 500)
  end

  test "supplier repair kit uses the same preflight without restaurant concepts" do
    stocks = %{
      "brake-kit" => stocked("workshop", "brake-kit", "each", 4),
      "washers" => stocked("workshop", "washers", "each", 24)
    }

    requirements = [
      %{item: "washers", unit: "each", per_unit: 4},
      %{item: "brake-kit", unit: "each", per_unit: 1}
    ]

    assert {:ok, candidate} =
             Basket.plan(stocks, "workshop", "kitchen", "repair-1", 2, requirements, 800)

    assert Enum.map(candidate.commands, & &1.item) == ["brake-kit", "washers"]
    assert Enum.map(candidate.commands, & &1.command.quantity) == [2, 8]
  end

  test "replayed and stale stock must be revalidated by the authoritative host" do
    first = stock()

    {:ok, candidate} =
      Basket.plan(first, "restaurant", "kitchen", "order-1", 1, ingredients(), 500)

    [cheese_command | _] = candidate.commands

    {:ok, reserved, :accepted} =
      InventoryCore.apply(first["cheese"], "restaurant", cheese_command.command)

    assert {:error, {"cheese", :already_reserved}} =
             Basket.plan(
               %{first | "cheese" => reserved},
               "restaurant",
               "kitchen",
               "order-1",
               1,
               ingredients(),
               500
             )

    {:ok, changed, :accepted} =
      InventoryCore.apply(first["dough"], "restaurant", %{
        id: "other-receipt",
        expected_version: 1,
        op: :receive,
        location: "kitchen",
        quantity: 1
      })

    dough_command = Enum.find(candidate.commands, &(&1.item == "dough")).command

    assert {:error, :stale_stock_version} =
             InventoryCore.apply(changed, "restaurant", dough_command)
  end

  test "rejects cross-merchant, wrong-unit, missing and duplicated requirements" do
    original = stock()
    requirements = ingredients()

    assert {:error, {"cheese", :stock_scope_mismatch}} =
             Basket.plan(original, "other", "kitchen", "order", 1, requirements, 500)

    wrong_unit = [%{item: "cheese", unit: "each", per_unit: 1}]

    assert {:error, {"cheese", :stock_scope_mismatch}} =
             Basket.plan(original, "restaurant", "kitchen", "order", 1, wrong_unit, 500)

    assert {:error, {"unknown", :unknown_stock}} =
             Basket.plan(
               original,
               "restaurant",
               "kitchen",
               "order",
               1,
               [%{item: "unknown", unit: "each", per_unit: 1}],
               500
             )

    assert {:error, :duplicate_basket_item} =
             Basket.plan(
               original,
               "restaurant",
               "kitchen",
               "order",
               1,
               requirements ++ [hd(requirements)],
               500
             )
  end

  test "rejects invalid and overflowing exact quantities before any proposal" do
    original = stock()

    assert {:error, :invalid_basket_count} =
             Basket.plan(original, "restaurant", "kitchen", "order", 0, ingredients(), 100)

    assert {:error, :invalid_basket_requirements} =
             Basket.plan(original, "restaurant", "kitchen", "order", 1, [], 100)

    assert {:error, :invalid_reservation_expiry} =
             Basket.plan(original, "restaurant", "kitchen", "order", 1, ingredients(), -1)

    assert {:error, {"cheese", :quantity_overflow}} =
             Basket.plan(
               original,
               "restaurant",
               "kitchen",
               "order",
               9_007_199_254_740_991,
               ingredients(),
               100
             )
  end

  property "the Menu.sellable bound agrees with every ingredient preflight" do
    check all(
            cheese_stock <- integer(1..500),
            dough_stock <- integer(1..500),
            cheese_per <- integer(1..80),
            dough_per <- integer(1..80),
            max_runs: 75
          ) do
      stocks = %{
        "cheese" => stocked("restaurant", "cheese", "grams", cheese_stock),
        "dough" => stocked("restaurant", "dough", "grams", dough_stock)
      }

      needs = [
        %{item: "cheese", unit: "grams", per_unit: cheese_per},
        %{item: "dough", unit: "grams", per_unit: dough_per}
      ]

      menu = Enum.map(needs, &%{item: &1.item, quantity: &1.per_unit})
      {:ok, sellable} = InventoryCore.Menu.sellable(menu, stocks, "restaurant", "kitchen")

      if sellable > 0 do
        assert {:ok, %{kind: :unsigned_inventory_basket}} =
                 Basket.plan(stocks, "restaurant", "kitchen", "order", sellable, needs, 100)
      end

      assert {:error, {_item, :insufficient_available}} =
               Basket.plan(stocks, "restaurant", "kitchen", "order", sellable + 1, needs, 100)
    end
  end

  test "supplied requirements have a stable command order regardless of input order" do
    original = stock()

    assert {:ok, a} =
             Basket.plan(original, "restaurant", "kitchen", "same", 1, ingredients(), 500)

    assert {:ok, b} =
             Basket.plan(
               original,
               "restaurant",
               "kitchen",
               "same",
               1,
               Enum.reverse(ingredients()),
               500
             )

    assert a == b
  end
end
