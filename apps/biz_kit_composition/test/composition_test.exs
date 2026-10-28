defmodule BizKit.CompositionTest do
  use ExUnit.Case, async: true

  alias BizKit.Composition
  alias CommerceCore.Catalog
  alias FulfillmentCore, as: Fulfillment
  alias InventoryCore, as: Stock

  defp merchant(name, sku, currency) do
    {:ok, catalog} = Catalog.new(name)

    {:ok, catalog} =
      Catalog.put(catalog, name, 0, %{
        id: "product",
        sku: sku,
        visibility: :published,
        prices: %{currency => Money.from_integer(650, currency)},
        variants: [],
        tax_context: "tax-not-computed"
      })

    {:ok, stock} = Stock.new(name, sku, "each")

    {:ok, stock, :accepted} =
      Stock.apply(stock, name, %{
        id: "receipt-1",
        expected_version: 0,
        op: :receive,
        location: "warehouse",
        quantity: 5
      })

    {catalog, stock}
  end

  defp options(merchant, currency, mode) do
    %{
      merchant: merchant,
      product_id: "product",
      currency: currency,
      quantity: 2,
      location: "warehouse",
      reserve_command_id: "reserve-1",
      reservation_id: "hold-1",
      expires_at_ms: 10_000,
      request_id: "request-1",
      order_id: "order-1",
      delivery_mode: mode
    }
  end

  test "restaurant order preview leaves commerce, inventory, and transport unmodified" do
    {catalog, stock} = merchant("restaurant", "MEAL", :USD)
    opts = options("restaurant", :USD, "restaurant-courier")

    assert {:ok, candidate} = Composition.preview(catalog, stock, opts)
    assert candidate.kind == :unsigned_preview
    assert candidate.catalog_revision == 1
    assert candidate.stock_revision == 1
    assert candidate.sku == "MEAL"
    assert Money.equal?(candidate.subtotal_estimate, Money.from_integer(1300, :USD))
    assert candidate.fulfillment_request.phase == :requested
    assert candidate.stock_reservation_command.expected_version == 1

    assert {:ok, 5} = Stock.available(stock, "restaurant", "warehouse")

    assert {:ok, original} =
             Fulfillment.new("restaurant", "request-1", "order-1", "restaurant-courier")

    assert candidate.fulfillment_request == original
    assert stock.reservations == %{}
  end

  test "supplier freight uses the same mechanisms with a different merchant and currency" do
    {catalog, stock} = merchant("parts-supplier", "BRAKE-KIT", :EUR)

    assert {:ok, candidate} =
             Composition.preview(catalog, stock, options("parts-supplier", :EUR, "freight"))

    assert candidate.merchant == "parts-supplier"
    assert candidate.fulfillment_request.mode == "freight"
    assert Money.equal?(candidate.subtotal_estimate, Money.from_integer(1300, :EUR))

    assert {:ok, committed, :accepted} =
             Stock.apply(stock, "parts-supplier", candidate.stock_reservation_command)

    assert {:ok, 3} = Stock.available(committed, "parts-supplier", "warehouse")
  end

  test "a wrong tenant and insufficient stock fail before any handoff is proposed" do
    {catalog, stock} = merchant("restaurant", "MEAL", :USD)
    opts = options("restaurant", :USD, "courier")

    assert {:error, :wrong_merchant} =
             Composition.preview(catalog, stock, %{opts | merchant: "competitor"})

    assert {:error, :insufficient_available} =
             Composition.preview(catalog, stock, %{opts | quantity: 6})

    assert {:error, :invalid_quantity} =
             Composition.preview(catalog, stock, %{opts | quantity: 0})

    assert {:error, :stock_item_mismatch} =
             Composition.preview(catalog, %{stock | item: "UNRELATED"}, opts)

    assert {:ok, 5} = Stock.available(stock, "restaurant", "warehouse")
  end

  test "the host must still reject a stale reservation after an intervening stock change" do
    {catalog, stock} = merchant("restaurant", "MEAL", :USD)

    {:ok, candidate} =
      Composition.preview(catalog, stock, options("restaurant", :USD, "courier"))

    {:ok, changed, :accepted} =
      Stock.apply(stock, "restaurant", %{
        id: "other-receipt",
        expected_version: stock.version,
        op: :receive,
        location: "warehouse",
        quantity: 1
      })

    assert {:error, :stale_stock_version} =
             Stock.apply(changed, "restaurant", candidate.stock_reservation_command)
  end
end
