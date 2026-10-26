defmodule BizKit.Composition.GroupBuy do
  @moduledoc """
  Pure seller-home checkout/stock/fulfillment *preview* for a group-buy round
  whose posted members-only rates were unlocked by locally admitted contracts
  and whose immutable quote was separately seller-sealed.

  Even a valid preview cannot authorize a real stock reservation, cash
  charge, purchase or delivery. The trusted host must verify every member
  contract and seller authority, serialize the accepted signed ledger writes,
  recheck catalog/stock revisions, collect authorized payments and reconcile
  independent fulfillment operations before reporting success.
  """

  alias CommerceCore.Catalog
  alias FulfillmentCore
  alias GroupBuyCore.Contracted
  alias InventoryCore

  @keys ~w(merchant product_id currency now location reserve_command_id
            reservation_id expires_at_ms buyer_requests delivery_mode)a

  @doc """
  Compose the seller-originated sealed group quote with a current published
  catalog SKU, proposed inventory hold and per-buyer delivery requests.

  Each buyer's opaque request/order IDs are host supplied and unique.
  This never embeds delivery addresses or public participant lists.
  """
  def preview(group_state, catalog, stock, opts) when is_map(opts) do
    with :ok <- opts_shape(opts),
         {:ok, quoted} <- Contracted.sealed_quote(group_state, opts.now),
         :ok <- merchant_bound(opts.merchant, quoted, stock),
         :ok <- currency_bound(opts.currency, quoted.currency),
         {:ok, product} <-
           Catalog.quote(catalog, opts.merchant, opts.product_id, nil, opts.currency),
         :ok <- sku_bound(product.sku, quoted.sku),
         :ok <- stock_unit_bound(stock, quoted.unit, quoted.sku),
         :ok <- expiry_bound(opts.expires_at_ms, opts.now, quoted.expires_at),
         {:ok, hold} <- reservation_candidate(stock, opts, quoted.contracted_quantity),
         {:ok, deliveries} <- handoffs(opts, quoted) do
      {:ok,
       %{
         kind: :unsigned_contracted_group_buy_checkout_preview,
         campaign_id: quoted.campaign_id,
         seller: quoted.seller,
         sku: quoted.sku,
         quote_hash: quoted.quote_hash,
         catalog_revision: product.catalog_version,
         stock_revision: stock.version,
         contracted_quantity: quoted.contracted_quantity,
         currency: quoted.currency,
         sealed_group_unit_minor: quoted.unlocked_group_unit_minor,
         standalone_cash_unit_minor: quoted.solo_unit_minor,
         commitments: quoted.members,
         stock_reservation_command: hold,
         fulfillment_requests: deliveries,
         catalog_price_compatibility: :requires_host_revalidation_of_seller_cash_price,
         payment_status: :not_authorized,
         inventory_status: :not_reserved,
         fulfillment_status: :not_dispatched,
         authority: :host_only_no_local_ledger_write
       }}
    end
  end

  def preview(_, _, _, _), do: {:error, :invalid_group_checkout_preview}

  defp opts_shape(opts) do
    if Enum.sort(Map.keys(opts)) == Enum.sort(@keys) and
         is_integer(opts.now) and opts.now >= 0 and
         is_atom(opts.currency) and
         is_binary(opts.merchant) and
         is_binary(opts.product_id) and
         is_binary(opts.location) and
         is_binary(opts.reserve_command_id) and
         is_binary(opts.reservation_id) and
         is_binary(opts.delivery_mode) and
         is_map(opts.buyer_requests) do
      :ok
    else
      {:error, :invalid_group_checkout_options}
    end
  end

  defp merchant_bound(merchant, %{seller: seller}, %{merchant: merchant})
       when seller == merchant,
       do: :ok

  defp merchant_bound(_, _, _), do: {:error, :seller_or_stock_scope_mismatch}

  defp currency_bound(currency, code) do
    if Atom.to_string(currency) == code,
      do: :ok,
      else: {:error, :currency_mismatch}
  end

  defp sku_bound(sku, sku), do: :ok
  defp sku_bound(_, _), do: {:error, :catalog_sku_mismatch}

  defp stock_unit_bound(%{unit: unit, item: sku}, unit, sku), do: :ok
  defp stock_unit_bound(_, _, _), do: {:error, :stock_item_or_unit_mismatch}

  defp expiry_bound(expires, now, quote_expiry)
       when is_integer(expires) and expires > now * 1_000 and
              expires <= quote_expiry * 1_000,
       do: :ok

  defp expiry_bound(_, _, _), do: {:error, :hold_exceeds_contract_expiry}

  defp reservation_candidate(stock, opts, count) do
    command = %{
      id: opts.reserve_command_id,
      expected_version: stock.version,
      op: :reserve,
      location: opts.location,
      quantity: count,
      reservation_id: opts.reservation_id,
      expires_at_ms: opts.expires_at_ms
    }

    case InventoryCore.apply(stock, opts.merchant, command) do
      {:ok, _temporary, :accepted} -> {:ok, command}
      {:ok, _temporary, :duplicate} -> {:error, :reservation_already_proposed}
      {:error, _} = error -> error
    end
  end

  defp handoffs(opts, quote) do
    buyers = Enum.map(quote.members, & &1.buyer)
    references = opts.buyer_requests

    valid_refs =
      Enum.sort(Map.keys(references)) == Enum.sort(buyers) and
        Enum.all?(Map.values(references), fn
          %{request_id: id, order_id: order} = refs when map_size(refs) == 2 ->
            valid_id?(id) and valid_id?(order)

          _ ->
            false
        end)

    if valid_refs do
      all_request_ids = Enum.map(Map.values(references), & &1.request_id)
      all_order_ids = Enum.map(Map.values(references), & &1.order_id)

      if Enum.uniq(all_request_ids) == all_request_ids and
           Enum.uniq(all_order_ids) == all_order_ids do
        quote.members
        |> Enum.reduce_while({:ok, []}, fn member, {:ok, acc} ->
          ref = Map.fetch!(references, member.buyer)

          case FulfillmentCore.new(
                 opts.merchant,
                 ref.request_id,
                 ref.order_id,
                 opts.delivery_mode
               ) do
            {:ok, handoff} ->
              {:cont,
               {:ok,
                [
                  %{
                    buyer: member.buyer,
                    quantity: member.quantity,
                    conditional_group_minor: member.group_minor,
                    handoff: handoff
                  }
                  | acc
                ]}}

            error ->
              {:halt, error}
          end
        end)
        |> case do
          {:ok, records} -> {:ok, Enum.reverse(records)}
          error -> error
        end
      else
        {:error, :duplicate_fulfillment_reference}
      end
    else
      {:error, :invalid_buyer_handoffs}
    end
  end

  defp valid_id?(value), do: is_binary(value) and byte_size(value) in 1..128
end
