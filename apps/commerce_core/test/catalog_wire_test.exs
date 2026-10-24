defmodule CommerceCore.CatalogWireTest do
  use ExUnit.Case, async: true

  alias CommerceCore.{Catalog, CatalogWire}

  @trusted %{merchant: "restaurant", allow_publish: true}

  defp price(currency, minor) do
    %{"currency" => currency, "minor_units" => minor}
  end

  defp product do
    %{
      "schema" => "bizkit.catalog.product.v1",
      "merchant" => "restaurant",
      "expected_version" => 0,
      "id" => "meal",
      "sku" => "MEAL",
      "visibility" => "published",
      "prices" => [price("USD", 1250), price("EUR", 1100)],
      "variants" => [
        %{
          "id" => "meal-large",
          "sku" => "MEAL-L",
          "prices" => [price("USD", 1700)]
        }
      ],
      "tax_context" => "us-restaurant-tax"
    }
  end

  test "decodes a bounded, multi-currency candidate without writing Eatsbot" do
    assert {:ok, %{expected_version: 0, product: decoded}} =
             CatalogWire.decode(product(), @trusted)

    {:ok, initial} = Catalog.new("restaurant")
    assert {:ok, state} = Catalog.put(initial, "restaurant", 0, decoded)
    assert {:ok, quote} = Catalog.quote(state, "restaurant", "meal", nil, :EUR)
    assert Money.equal?(quote.unit_price, Money.from_integer(1100, :EUR))
    assert quote.catalog_version == 1

    assert {:ok, variant} =
             Catalog.quote(state, "restaurant", "meal", "meal-large", :USD)

    assert Money.equal?(variant.unit_price, Money.from_integer(1700, :USD))
  end

  test "a nonrestaurant supplier uses exactly the same price/product rules" do
    wire = %{
      product()
      | "merchant" => "supplier",
        "sku" => "PART-KIT",
        "tax_context" => "workshop-parts"
    }

    assert {:ok, %{product: item}} =
             CatalogWire.decode(wire, %{merchant: "supplier", allow_publish: true})

    assert item.sku == "PART-KIT"
    assert item.tax_context == "workshop-parts"
  end

  test "merchant spoof and attempts to publish without a grant are refused" do
    assert {:error, :wrong_merchant} =
             CatalogWire.decode(%{product() | "merchant" => "another"}, @trusted)

    assert {:error, :publication_not_authorized} =
             CatalogWire.decode(product(), %{merchant: "restaurant", allow_publish: false})

    hidden = %{product() | "visibility" => "hidden"}

    assert {:ok, %{product: %{visibility: :hidden}}} =
             CatalogWire.decode(hidden, %{merchant: "restaurant"})
  end

  test "refuses duplicate currencies, unknown money and fractional prices" do
    duplicate = %{product() | "prices" => [price("USD", 1250), price("USD", 1500)]}

    assert {:error, :duplicate_catalog_currency} =
             CatalogWire.decode(duplicate, @trusted)

    assert {:error, :unsupported_catalog_value} =
             CatalogWire.decode(%{product() | "prices" => [price("FAKE", 100)]}, @trusted)

    for minor <- [0, -1, 1.5, "100", 9_007_199_254_740_992] do
      assert {:error, :invalid_catalog_number} =
               CatalogWire.decode(%{product() | "prices" => [price("USD", minor)]}, @trusted)
    end
  end

  test "rejects role injection, unknown fields, version gaps and unsafe cardinality" do
    assert {:error, :invalid_catalog_shape} =
             CatalogWire.decode(Map.put(product(), "actor", "administrator"), @trusted)

    assert {:error, :unsupported_catalog_schema} =
             CatalogWire.decode(%{product() | "schema" => "bizkit.catalog.product.v2"}, @trusted)

    assert {:error, :invalid_catalog_number} =
             CatalogWire.decode(%{product() | "expected_version" => -1}, @trusted)

    assert {:error, :invalid_catalog_variants} =
             CatalogWire.decode(%{product() | "variants" => List.duplicate(hd(product()["variants"]), 65)}, @trusted)
  end

  test "catalog reducer still owns cross-product SKU and revision conflicts" do
    {:ok, %{product: meal}} = CatalogWire.decode(product(), @trusted)
    {:ok, initial} = Catalog.new("restaurant")
    {:ok, first} = Catalog.put(initial, "restaurant", 0, meal)

    assert {:error, :stale_catalog_revision} =
             Catalog.put(first, "restaurant", 0, meal)

    duplicate = %{meal | id: "another", sku: "MEAL-L", variants: []}

    assert {:error, :duplicate_sku} =
             Catalog.put(first, "restaurant", first.version, duplicate)
  end
end
