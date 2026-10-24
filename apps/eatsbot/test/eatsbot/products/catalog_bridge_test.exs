defmodule EatsbotCore.Products.CatalogBridgeTest do
  use ExUnit.Case, async: true

  alias CommerceCore.Catalog
  alias EatsbotCore.Products.CatalogBridge

  test "projecting loaded Eatsbot products does not alter the Ash writer" do
    product = %{
      id: "meal",
      sku: "MEAL",
      state: :enabled,
      prices: [%{money: Money.from_integer(1500, :USD)}],
      variants: [
        %{
          id: "large",
          sku: "LARGE",
          prices: [%{money: Money.from_integer(2000, :USD)}]
        }
      ]
    }

    {:ok, catalog} = CatalogBridge.preview("restaurant", product)
    {:ok, quote} = Catalog.quote(catalog, "restaurant", "meal", "large", :USD)
    assert quote.sku == "LARGE"
    assert Money.equal?(quote.unit_price, Money.from_integer(2000, :USD))
  end

  test "unloaded prices and wrong scopes are refused" do
    product = %{id: "meal", sku: "MEAL", state: :enabled, prices: nil}
    assert {:error, :unloaded_catalog_projection} = CatalogBridge.preview("r", product)
    assert {:error, :invalid_merchant} = CatalogBridge.preview("", product)
  end
end
