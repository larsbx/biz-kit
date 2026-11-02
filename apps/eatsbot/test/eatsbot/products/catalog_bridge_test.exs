defmodule EatsbotCore.Products.CatalogBridgeTest do
  use ExUnit.Case, async: true

  alias CommerceCore.Catalog
  alias EatsbotCore.Products.CatalogBridge

  @source %{
    home_id: "home-a",
    merchant: "restaurant",
    source_id: "legacy-a",
    mode: :isolated_runtime
  }
  @trusted %{
    home_id: "home-a",
    merchant: "restaurant",
    source_id: "legacy-a",
    principal: "ada",
    granted: true,
    operation: :catalog_read
  }

  defp product do
    %{
      id: "meal",
      sku: "MEAL",
      state: :enabled,
      prices: [%{money: Money.from_integer(1500, :USD)}],
      variants: [
        %{id: "large", sku: "LARGE", prices: [%{money: Money.from_integer(2000, :USD)}]}
      ]
    }
  end

  test "isolated source projection carries home and merchant without altering the Ash writer" do
    {:ok, catalog} = CatalogBridge.preview(@source, @trusted, fn -> {:ok, product()} end)
    {:ok, quote} = Catalog.quote(catalog, @source, "meal", "large", :USD)
    assert quote.home_id == "home-a"
    assert quote.merchant == "restaurant"
    assert quote.sku == "LARGE"
    assert Money.equal?(quote.unit_price, Money.from_integer(2000, :USD))
  end

  test "foreign, revoked, unbound and shared sources refuse before any loading" do
    loader = fn -> flunk("refused authority must not reach a source read") end

    for trusted <- [
          %{@trusted | home_id: "home-b"},
          %{@trusted | merchant: "another"},
          %{@trusted | source_id: "legacy-b"},
          %{@trusted | granted: false},
          %{@trusted | operation: :checkout},
          Map.delete(@trusted, :home_id),
          %{}
        ] do
      assert CatalogBridge.preview(@source, trusted, loader) == {:error, :forbidden}
    end

    for source <- [
          %{@source | mode: :shared_database},
          Map.delete(@source, :source_id),
          Map.delete(@source, :home_id),
          %{}
        ] do
      assert CatalogBridge.preview(source, @trusted, loader) == {:error, :forbidden}
    end

    # The old two-argument projector may not launder an unowned row into a home.
    assert apply(CatalogBridge, :preview, ["restaurant", product()]) == {:error, :forbidden}
  end

  test "unloaded snapshots and loader errors are refused without partial projections" do
    for item <- [
          %{product() | prices: nil},
          Map.delete(product(), :variants),
          %{product() | variants: [nil]},
          nil
        ] do
      assert CatalogBridge.preview(@source, @trusted, fn -> {:ok, item} end) ==
               {:error, :unloaded_catalog_projection}
    end

    assert CatalogBridge.preview(@source, @trusted, fn -> {:error, :unavailable} end) ==
             {:error, :unavailable}
  end
end
