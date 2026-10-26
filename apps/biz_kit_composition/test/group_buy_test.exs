defmodule BizKit.Composition.GroupBuyTest do
  use ExUnit.Case, async: true

  alias BizKit.Composition.GroupBuy
  alias CommerceCore.Catalog
  alias GroupBuyCore.Contracted
  alias InventoryCore

  @now 1_800_000_000
  @seller "https://seller.example/actors/shop"

  defp offer do
    %{
      id: "https://seller.example/group-buys/part-a",
      seller: @seller,
      sku: "part-a",
      unit: "piece",
      currency: "USD",
      revision: 7,
      expires_at: @now + 2_000,
      capacity: 20,
      solo_unit_minor: 10_000,
      tiers: [%{min_quantity: 5, unit_minor: 9_000}]
    }
  end

  defp buyer(name), do: "https://#{name}.example/actors/member"

  defp admitted(state, name, count) do
    command = %{
      id: "cmd-" <> name,
      expected_version: state.version,
      op: :contract,
      buyer: buyer(name),
      offer_id: offer().id,
      offer_revision: 7,
      contract_id: "contract-" <> name,
      quantity: count,
      max_group_unit_minor: 9_000,
      expires_at: @now + 1_000,
      evidence_ref: "authenticated-signature-needs-host-validation-" <> name
    }

    {:ok, state, :accepted} = Contracted.apply(state, buyer(name), command, @now)
    state
  end

  defp sealed_group do
    {:ok, state} = Contracted.new(offer(), @now)
    state = admitted(state, "a", 3)
    state = admitted(state, "b", 2)
    {:ok, q} = Contracted.quote(state, @now)

    command = %{
      id: "seller-seal",
      expected_version: state.version,
      op: :seal,
      expected_quote_hash: q.quote_hash,
      evidence_ref: "seller-signed-terms-host-must-verify"
    }

    {:ok, state, :accepted} = Contracted.apply(state, @seller, command, @now)
    state
  end

  defp catalog do
    {:ok, state} = Catalog.new(@seller)

    {:ok, state} =
      Catalog.put(state, @seller, 0, %{
        id: "part",
        sku: "part-a",
        visibility: :published,
        prices: %{USD: Money.from_integer(100, :USD)},
        variants: [],
        tax_context: "tax-shipping-not-computed"
      })

    state
  end

  defp stock(count \\ 8) do
    {:ok, state} = InventoryCore.new(@seller, "part-a", "piece")

    {:ok, state, :accepted} =
      InventoryCore.apply(state, @seller, %{
        id: "supply",
        expected_version: state.version,
        op: :receive,
        location: "warehouse",
        quantity: count
      })

    state
  end

  defp opts do
    %{
      merchant: @seller,
      product_id: "part",
      currency: :USD,
      now: @now,
      location: "warehouse",
      reserve_command_id: "group-buy-stock-hold",
      reservation_id: "group-buy-reservation",
      expires_at_ms: (@now + 800) * 1_000,
      delivery_mode: "collective-pickup",
      buyer_requests: %{
        buyer("a") => %{request_id: "shipment-a", order_id: "order-a"},
        buyer("b") => %{request_id: "shipment-b", order_id: "order-b"}
      }
    }
  end

  test "seller-only host previews a single stock hold and distinct per-buyer fulfillment" do
    state = sealed_group()
    starting = stock()

    assert {:ok, preview} = GroupBuy.preview(state, catalog(), starting, opts())
    assert preview.kind == :unsigned_contracted_group_buy_checkout_preview
    assert preview.contracted_quantity == 5
    assert preview.sealed_group_unit_minor == 9_000
    assert preview.standalone_cash_unit_minor == 10_000
    assert preview.catalog_revision == 1
    assert preview.stock_revision == 1
    assert preview.inventory_status == :not_reserved
    assert preview.payment_status == :not_authorized
    assert preview.fulfillment_status == :not_dispatched
    assert preview.catalog_price_compatibility == :requires_host_revalidation_of_seller_cash_price

    hold = preview.stock_reservation_command
    assert hold.op == :reserve
    assert hold.quantity == 5
    assert hold.expected_version == starting.version
    assert length(preview.fulfillment_requests) == 2
    assert Enum.all?(preview.fulfillment_requests, &(&1.handoff.phase == :requested))
    assert Enum.sort(Enum.map(preview.fulfillment_requests, & &1.quantity)) == [2, 3]
    assert {:ok, 8} = InventoryCore.available(starting, @seller, "warehouse")
    assert starting.reservations == %{}
  end

  test "applying a seller-authorized hold blocks direct sale from overselling" do
    state = sealed_group()
    stock = stock(5)
    {:ok, preview} = GroupBuy.preview(state, catalog(), stock, opts())

    {:ok, held, :accepted} =
      InventoryCore.apply(stock, @seller, preview.stock_reservation_command)

    assert {:ok, 0} = InventoryCore.available(held, @seller, "warehouse")

    assert {:error, :insufficient_available} =
             InventoryCore.apply(held, @seller, %{
               id: "direct-cash-sale-hold",
               expected_version: held.version,
               op: :reserve,
               location: "warehouse",
               quantity: 1,
               reservation_id: "cash-customer",
               expires_at_ms: (@now + 900) * 1_000
             })

    assert {:error, :stale_stock_version} =
             InventoryCore.apply(held, @seller, preview.stock_reservation_command)
  end

  test "unsealed or below-threshold demand never receives a reservation preview" do
    {:ok, empty} = Contracted.new(offer(), @now)

    assert {:error, :not_currently_sealed} =
             GroupBuy.preview(empty, catalog(), stock(), opts())

    partial = admitted(empty, "a", 3)

    assert {:error, :not_currently_sealed} =
             GroupBuy.preview(partial, catalog(), stock(), opts())
  end

  test "seller, SKU, inventory unit and currency must match local authoritative cores" do
    group = sealed_group()

    assert {:error, :seller_or_stock_scope_mismatch} =
             GroupBuy.preview(group, catalog(), stock(), %{opts() | merchant: "another-seller"})

    {:ok, different_catalog} =
      Catalog.put(catalog(), @seller, 1, %{
        id: "part",
        sku: "different-sku",
        visibility: :published,
        prices: %{USD: Money.from_integer(100, :USD)},
        variants: [],
        tax_context: "tax-shipping-not-computed"
      })

    assert {:error, :catalog_sku_mismatch} =
             GroupBuy.preview(group, different_catalog, stock(), opts())

    assert {:error, :stock_item_or_unit_mismatch} =
             GroupBuy.preview(group, catalog(), %{stock() | unit: "kg"}, opts())

    assert {:error, :currency_mismatch} =
             GroupBuy.preview(group, catalog(), stock(), %{opts() | currency: :EUR})
  end

  test "short stock, expired hold and mismatched buyer fulfillment references refuse" do
    group = sealed_group()

    assert {:error, :insufficient_available} =
             GroupBuy.preview(group, catalog(), stock(4), opts())

    assert {:error, :hold_exceeds_contract_expiry} =
             GroupBuy.preview(
               group,
               catalog(),
               stock(),
               %{opts() | expires_at_ms: (@now + 1_100) * 1_000}
             )

    assert {:error, :invalid_buyer_handoffs} =
             GroupBuy.preview(group, catalog(), stock(), %{opts() | buyer_requests: %{}})

    bad =
      Map.put(opts().buyer_requests, buyer("b"), %{
        request_id: "shipment-a",
        order_id: "order-b"
      })

    assert {:error, :duplicate_fulfillment_reference} =
             GroupBuy.preview(group, catalog(), stock(), %{opts() | buyer_requests: bad})
  end
end
