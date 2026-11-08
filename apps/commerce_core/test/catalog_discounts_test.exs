defmodule CommerceCore.CatalogDiscountsTest do
  @moduledoc """
  Discount rules on catalog products (Eatsbot decommission D5): a product may
  carry `discounts`, validated by `CommerceCore.Discounts` when the product is
  put, and a quote returns them for the host to apply at its quantity.
  """
  use ExUnit.Case, async: true

  alias CommerceCore.{Catalog, Discounts}

  @merchant "pizzeria"

  defp m(minor), do: Money.from_integer(minor, :USD)

  defp pizza(discounts),
    do: %{
      id: "margherita",
      sku: "MARG",
      visibility: :published,
      prices: %{USD: m(1250)},
      discounts: discounts
    }

  defp put(product) do
    {:ok, empty} = Catalog.new(@merchant)
    Catalog.put(empty, @merchant, 0, product)
  end

  test "a quote returns the product's normalized discount rules" do
    lunch = %{id: "lunch", method: :percent_off, rate: Decimal.new("0.2"), hours: {11, 14}}
    assert {:ok, state} = put(pizza([lunch]))
    assert {:ok, q} = Catalog.quote(state, @merchant, "margherita", nil, :USD)
    assert {:ok, normalized} = Discounts.normalize(lunch)
    assert q.discounts == [normalized]
  end

  test "a product without discounts quotes none" do
    assert {:ok, state} = put(Map.delete(pizza([]), :discounts))
    assert {:ok, %{discounts: []}} = Catalog.quote(state, @merchant, "margherita", nil, :USD)
  end

  test "an invalid or repeated rule refuses the whole product" do
    ok = %{id: "two-for-one", method: :buy_x_pay_y, x: 2, y: 1}

    assert {:error, :invalid_discounts} = put(pizza([%{ok | y: 2}]))
    assert {:error, :invalid_discounts} = put(pizza([ok, ok]))
    assert {:error, :invalid_discounts} = put(pizza(:none))
  end
end
