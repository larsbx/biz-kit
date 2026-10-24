defmodule BizKit.Composition do
  @moduledoc """
  Compose pure, pre-admission commercial and transportation *candidates*.

  The sales price, reservation, and handoff request are three distinct
  business facts. This function only verifies a single observed snapshot and
  proposes commands. It does not commit anything, reserve stock, collect money,
  dispatch a driver, or establish a distributed transaction.

  The authorized host must check the current catalog/stock revisions,
  authenticate the merchant, serialize stock admission, durably append each
  source-owned event, and reconcile partial failures before acknowledging.
  """

  alias CommerceCore.{Catalog, Pricing}
  alias FulfillmentCore, as: Fulfillment
  alias InventoryCore, as: Stock

  @doc """
  Preview a one-line physical-goods order and delivery handoff.

  Required options: `:merchant`, `:product_id`, `:currency`,
  `:quantity`, `:location`, `:reserve_command_id`,
  `:reservation_id`, `:expires_at_ms`, `:request_id`,
  `:order_id`, and `:delivery_mode`. Optional `:variant_id` defaults
  to `nil`. No recipient PII is accepted or returned.

  All totals exclude tax, fees, promotional discounts and tips. They are
  illustrative line estimates, not a price or tax guarantee.
  """
  def preview(catalog, stock, opts) when is_map(catalog) and is_map(stock) and is_map(opts) do
    merchant = Map.get(opts, :merchant)
    quantity = Map.get(opts, :quantity)

    with :ok <- positive(quantity),
         {:ok, quote} <-
           Catalog.quote(
             catalog,
             merchant,
             Map.get(opts, :product_id),
             Map.get(opts, :variant_id),
             Map.get(opts, :currency)
           ),
         :ok <- stock_item(stock, quote.sku),
         {:ok, handoff} <-
           Fulfillment.new(
             merchant,
             Map.get(opts, :request_id),
             Map.get(opts, :order_id),
             Map.get(opts, :delivery_mode)
           ),
         {:ok, estimate} <- estimate(quote.unit_price, quantity, Map.get(opts, :currency)),
         {:ok, reserve} <- reserve_candidate(stock, merchant, opts, quantity) do
      {:ok,
       %{
         kind: :unsigned_preview,
         merchant: merchant,
         catalog_revision: quote.catalog_version,
         stock_revision: stock.version,
         sku: quote.sku,
         unit_price: quote.unit_price,
         quantity: quantity,
         subtotal_estimate: estimate.subtotal,
         tax_context: quote.tax_context,
         stock_reservation_command: reserve,
         fulfillment_request: handoff
       }}
    end
  end

  def preview(_, _, _), do: {:error, :invalid_composition_request}

  defp positive(n) when is_integer(n) and n > 0, do: :ok
  defp positive(_), do: {:error, :invalid_quantity}

  defp stock_item(%{item: sku}, sku), do: :ok
  defp stock_item(_, _), do: {:error, :stock_item_mismatch}

  defp estimate(unit_price, quantity, currency) do
    zero = Money.zero(currency)

    Pricing.price(
      currency,
      [%{unit_price: unit_price, quantity: quantity, discount: zero}],
      %{discount_total: zero, tax_total: zero, delivery_fee: zero, tip: zero}
    )
  end

  defp reserve_candidate(stock, merchant, opts, quantity) do
    command = %{
      id: Map.get(opts, :reserve_command_id),
      expected_version: Map.get(stock, :version),
      op: :reserve,
      location: Map.get(opts, :location),
      quantity: quantity,
      reservation_id: Map.get(opts, :reservation_id),
      expires_at_ms: Map.get(opts, :expires_at_ms)
    }

    case Stock.apply(stock, merchant, command) do
      {:ok, _next, :accepted} -> {:ok, command}
      {:ok, _next, :duplicate} -> {:error, :already_proposed}
      {:error, _} = error -> error
    end
  end
end
