defmodule InventoryCore.MenuTest do
  @moduledoc """
  Menu availability from stock (eatsbot rebuild, slice 2): how many units of a menu
  item can still be sold at a location, and whether it is 86'd (none can).
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias InventoryCore.Menu

  @merchant "pizzeria"
  @kitchen "kitchen"

  defp stock(item, received, reserved \\ 0) do
    {:ok, state} = InventoryCore.new(@merchant, item, "each")

    state =
      if received > 0,
        do: apply!(state, "in", :receive, %{location: @kitchen, quantity: received}),
        else: state

    if reserved > 0,
      do:
        apply!(state, "hold", :reserve, %{
          location: @kitchen,
          quantity: reserved,
          reservation_id: "h",
          expires_at_ms: 1
        }),
      else: state
  end

  defp apply!(state, id, op, attrs) do
    {:ok, next, :accepted} =
      InventoryCore.apply(
        state,
        @merchant,
        Map.merge(%{id: id, expected_version: state.version, op: op}, attrs)
      )

    next
  end

  defp pizza, do: [%{item: "dough", quantity: 1}, %{item: "cheese", quantity: 120}]

  test "the scarcest ingredient decides how many can be sold" do
    stocks = %{"dough" => stock("dough", 5), "cheese" => stock("cheese", 500)}
    assert {:ok, 4} = Menu.sellable(pizza(), stocks, @merchant, @kitchen)
  end

  test "reserved stock is not sellable" do
    stocks = %{"dough" => stock("dough", 5), "cheese" => stock("cheese", 500, 260)}
    assert {:ok, 2} = Menu.sellable(pizza(), stocks, @merchant, @kitchen)
  end

  test "an item none of which can be sold is 86'd" do
    stocks = %{"dough" => stock("dough", 0), "cheese" => stock("cheese", 500)}
    assert {:ok, 0} = Menu.sellable(pizza(), stocks, @merchant, @kitchen)
    assert Menu.eighty_sixed?(pizza(), stocks, @merchant, @kitchen)

    stocks = %{stocks | "dough" => stock("dough", 1)}
    refute Menu.eighty_sixed?(pizza(), stocks, @merchant, @kitchen)
  end

  test "an item that uses no tracked stock is never limited" do
    assert {:ok, :unlimited} = Menu.sellable([], %{}, @merchant, @kitchen)
    refute Menu.eighty_sixed?([], %{}, @merchant, @kitchen)
  end

  test "unknown stock, bad requirements and another merchant are refused" do
    stocks = %{"dough" => stock("dough", 5)}

    assert {:error, {:unknown_stock, "cheese"}} =
             Menu.sellable(pizza(), stocks, @merchant, @kitchen)

    for bad <- [
          [%{item: "dough", quantity: 0}],
          [%{item: "dough", quantity: -1}],
          [%{item: "dough", quantity: 1.5}],
          [%{item: "", quantity: 1}],
          [%{item: "dough"}],
          [%{item: "dough", quantity: 1}, %{item: "dough", quantity: 2}],
          :dough
        ] do
      assert {:error, :invalid_requirements} = Menu.sellable(bad, stocks, @merchant, @kitchen),
             inspect(bad)
    end

    assert {:error, :wrong_merchant} =
             Menu.sellable([%{item: "dough", quantity: 1}], stocks, "other", @kitchen)

    # A stock aggregate filed under the wrong item is refused, not counted.
    assert {:error, {:stock_item_mismatch, "dough"}} =
             Menu.sellable(
               [%{item: "dough", quantity: 1}],
               %{"dough" => stock("flour", 5)},
               @merchant,
               @kitchen
             )

    assert true == Menu.eighty_sixed?(pizza(), stocks, @merchant, @kitchen)
  end

  property "n can be reserved for every ingredient, and n + 1 cannot for some" do
    check all(
            needs <-
              list_of({integer(1..50), integer(0..400), integer(0..100)},
                min_length: 1,
                max_length: 4
              )
          ) do
      requirements =
        for {{q, _, _}, i} <- Enum.with_index(needs), do: %{item: "i#{i}", quantity: q}

      stocks =
        for {{_, received, held_pct}, i} <- Enum.with_index(needs), into: %{} do
          {"i#{i}", stock("i#{i}", received, div(received * held_pct, 100))}
        end

      {:ok, n} = Menu.sellable(requirements, stocks, @merchant, @kitchen)

      reserve = fn units ->
        for %{item: item, quantity: q} <- requirements do
          command = %{
            id: "menu",
            expected_version: stocks[item].version,
            op: :reserve,
            location: @kitchen,
            quantity: units * q,
            reservation_id: "menu",
            expires_at_ms: 10
          }

          units == 0 or
            match?({:ok, _, :accepted}, InventoryCore.apply(stocks[item], @merchant, command))
        end
      end

      assert Enum.all?(reserve.(n))
      refute Enum.all?(reserve.(n + 1))
    end
  end
end
