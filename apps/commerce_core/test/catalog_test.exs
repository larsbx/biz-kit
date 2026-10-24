defmodule CommerceCore.CatalogTest do
  use ExUnit.Case, async: true

  alias CommerceCore.Catalog

  defp product(id, sku) do
    %{
      id: id,
      sku: sku,
      visibility: :published,
      prices: %{USD: Money.from_integer(1500, :USD)},
      tax_context: "tax-in-merchant-jurisdiction",
      variants: [
        %{
          id: "#{id}-large",
          sku: "#{sku}-L",
          prices: %{USD: Money.from_integer(2000, :USD)}
        }
      ]
    }
  end

  test "a merchant's priced revision is not readable by another merchant" do
    {:ok, empty} = Catalog.new("restaurant-A")
    {:ok, state} = Catalog.put(empty, "restaurant-A", 0, product("meal", "SKU-A"))

    assert state.version == 1
    assert {:ok, quote} = Catalog.quote(state, "restaurant-A", "meal", nil, :USD)
    assert quote.catalog_version == 1
    assert quote.sku == "SKU-A"
    assert Money.equal?(quote.unit_price, Money.from_integer(1500, :USD))

    assert {:ok, variant} =
             Catalog.quote(state, "restaurant-A", "meal", "meal-large", :USD)

    assert variant.sku == "SKU-A-L"

    assert {:error, :wrong_merchant} =
             Catalog.quote(state, "restaurant-B", "meal", nil, :USD)

    assert {:error, :wrong_merchant} =
             Catalog.put(state, "restaurant-B", 1, product("new", "NEW"))
  end

  test "optimistic revision prevents stale catalog and price publication" do
    {:ok, empty} = Catalog.new("restaurant")
    {:ok, first} = Catalog.put(empty, "restaurant", 0, product("meal", "MEAL"))

    assert {:error, :stale_catalog_revision} =
             Catalog.put(first, "restaurant", 0, product("meal", "MEAL"))

    changed = put_in(product("meal", "MEAL"), [:prices, :USD], Money.from_integer(2500, :USD))
    {:ok, updated} = Catalog.put(first, "restaurant", 1, changed)

    assert updated.version == 2
    {:ok, quoted} = Catalog.quote(updated, "restaurant", "meal", nil, :USD)
    assert Money.equal?(quoted.unit_price, Money.from_integer(2500, :USD))
  end

  test "SKU collisions, bad currency and hidden product fail closed" do
    {:ok, empty} = Catalog.new("merchant")
    {:ok, first} = Catalog.put(empty, "merchant", 0, product("one", "ONE"))

    assert {:error, :duplicate_sku} =
             Catalog.put(first, "merchant", 1, product("two", "ONE-L"))

    wrong = put_in(product("two", "TWO"), [:prices, :USD], Money.from_integer(5, :EUR))
    assert {:error, :invalid_prices} = Catalog.put(first, "merchant", 1, wrong)

    duplicate = %{product("two", "TWO") | variants: [
      %{id: "a", sku: "TWO", prices: %{USD: Money.from_integer(1, :USD)}}
    ]}

    assert {:error, :duplicate_sku} = Catalog.put(first, "merchant", 1, duplicate)

    hidden = %{product("hidden", "HIDDEN") | visibility: :hidden}
    {:ok, second} = Catalog.put(first, "merchant", 1, hidden)
    assert {:error, :not_published} = Catalog.quote(second, "merchant", "hidden", nil, :USD)
    assert {:error, :currency_not_offered} =
             Catalog.quote(second, "merchant", "one", nil, :EUR)
  end

  test "a nonrestaurant school-supplies merchant uses the identical rules" do
    {:ok, empty} = Catalog.new("supplies-store")

    kit = %{
      id: "blocks",
      sku: "MATH-BLOCKS",
      visibility: :published,
      prices: %{EUR: Money.from_integer(850, :EUR)},
      variants: [],
      tax_context: "school-supply-retail"
    }

    {:ok, state} = Catalog.put(empty, "supplies-store", 0, kit)
    {:ok, quote} = Catalog.quote(state, "supplies-store", "blocks", nil, :EUR)
    assert quote.tax_context == "school-supply-retail"
    assert quote.merchant == "supplies-store"
    assert {:error, :unknown_product} = Catalog.fetch(state, "supplies-store", "learner")
  end
end
