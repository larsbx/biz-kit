defmodule CoopSubstrate.GroupBuys.Stock do
  @moduledoc """
  Canonical seller-home group-buy stock receipts and escrow-gated holds.

  The one signed CoopSubstrate.Log admits these commands. They project
  InventoryCore against a shared seller/SKU/unit aggregate across campaigns,
  not a new stock ledger. A receive event represents seller-ASSERTED stock
  and cannot prove that physical goods exist. A reservation represents a
  signed local inventory hold, not delivery or irrevocable title transfer.

  Every group reservation requires seller-home admitted, still binding
  pledged quantity AND current externally signed escrow evidence for every
  buyer. A read-side readiness proof is invalidated by changed commitments,
  expired/disputed funds, stock expiry, or stale group terms.
  """

  alias GroupBuyCore.{BindingRound, Escrow}
  alias InventoryCore
  alias InventoryCore.Wire

  @event_type "GroupBuyStockCommandAdmittedV1"

  @doc "One private, seller-signed canonical event type."
  def event_type, do: @event_type

  @doc "Typed command proposal; never executes or appends an event by itself."
  def apply_event(
        %{chapter_id: chapter, payload: p, signers: signers, event_id: event_id},
        gate,
        now
      ) do
    key = {chapter, p["seller_id"], p["campaign_id"]}
    row = gate.group_buys.offers[key]
    round = gate.group_buys.rounds[key]

    with :ok <- seller_authorized(gate, chapter, p["seller_id"], signers, now),
         %{closed: closed} <- row,
         %{offer: offer} <- round,
         :ok <- reference(p["source_ref"]),
         {:ok, command} <-
           Wire.decode(p["command"], %{
             "merchant" => offer.seller,
             "item" => offer.sku,
             "unit" => offer.unit
           }),
         {:ok, stock} <- stock_for(gate, chapter, offer),
         :ok <- admissible(command, gate, key, round, stock, closed, now),
         {:ok, updated, :accepted} <- InventoryCore.apply(stock, offer.seller, command) do
      aggregate = stock_key(chapter, offer)

      next =
        gate.group_buys
        |> put_in([:stock_aggregates, Access.key(aggregate)], updated)
        |> claim(key, aggregate, round, command, event_id, now)

      {:ok, next}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_or_untrusted_group_stock_command}
    end
  end

  @doc """
  Return a read-only evidence-bound **candidate** to fulfill a group.
  This requires committed seller-home stock reservation and fresh escrow
  coverage for the identical binding terms hash. Actual physical stock,
  provider custody/release, tax and delivery must still be checked off-ledger.
  """
  def readiness(gate, chapter, seller, campaign, now)
      when is_integer(now) and now >= 0 do
    key = {chapter, seller, campaign}
    round = gate.group_buys.rounds[key]
    escrow = gate.group_buys.escrow_states[key]
    claim = gate.group_buys.stock_claims[key]

    with %{offer: _offer} <- round,
         %{
           reservation_id: reservation_id,
           terms_hash: terms_hash,
           quantity: count,
           stock_key: aggregate
         } <- claim,
         {:ok, %{status: :binding_threshold_activated} = bound} <-
           BindingRound.snapshot(round, now),
         true <-
           bound.terms_hash == terms_hash and
             count == bound.contracted_quantity,
         {:ok, coverage} <- Escrow.coverage(escrow, round, now),
         true <-
           coverage.binding_terms_hash == terms_hash and
             coverage.committed_units == count,
         :ok <- all_funds_held(escrow, round, now),
         %{reservations: reservations} <- gate.group_buys.stock_aggregates[aggregate],
         %{status: :active, remaining: ^count, expires_at_ms: expiry} <-
           reservations[reservation_id],
         true <- expiry > now * 1_000 do
      {:ok,
       %{
         campaign_id: campaign,
         binding_terms_hash: terms_hash,
         contracted_quantity: count,
         currency: bound.currency,
         verified_provider_funding_minor: coverage.secured_minor,
         current_due_minor: coverage.current_group_due_minor,
         stock_reservation_id: reservation_id,
         stock_expires_at_ms: expiry,
         assurance: :seller_home_committed_stock_and_provider_evidence,
         settlement: :not_authorized,
         physical_stock: :not_independently_verified,
         provider_custody: :requires_fresh_provider_reconciliation,
         fulfillment: :requires_external_delivery_checks
       }}
    else
      _ -> {:error, :escrow_or_stock_not_ready}
    end
  end

  def readiness(_, _, _, _, _), do: {:error, :escrow_or_stock_not_ready}

  defp admissible(%{op: :receive}, _gate, _key, _round, _stock, _closed, _now),
    do: :ok

  defp admissible(%{op: :reserve} = cmd, gate, key, round, stock, closed, now) do
    escrow = gate.group_buys.escrow_states[key]

    with false <- closed,
         nil <- gate.group_buys.stock_claims[key],
         {:ok, %{status: :binding_threshold_activated} = bound} <-
           BindingRound.snapshot(round, now),
         true <- cmd.quantity == bound.contracted_quantity and cmd.quantity > 0,
         {:ok, coverage} <- Escrow.coverage(escrow, round, now),
         true <- coverage.binding_terms_hash == bound.terms_hash,
         :ok <- all_funds_held(escrow, round, now),
         true <-
           is_integer(cmd.expires_at_ms) and
             cmd.expires_at_ms > now * 1_000,
         true <-
           Enum.all?(Map.values(escrow.positions), fn position ->
             position.expires_at * 1_000 >= cmd.expires_at_ms
           end),
         true <- not Map.has_key?(stock.reservations, cmd.reservation_id) do
      :ok
    else
      _ -> {:error, :stock_hold_requires_bound_funded_campaign}
    end
  end

  defp admissible(_, _, _, _, _, _, _), do: {:error, :stock_command_not_allowed}

  defp all_funds_held(escrow, round, now) do
    if Enum.all?(round.pledges, fn {buyer, pledge} ->
         case escrow.positions[buyer] do
           %{status: :held, pledge_id: id, expires_at: expiry}
           when id == pledge.id and expiry > now ->
             true

           _ ->
             false
         end
       end),
       do: :ok,
       else: {:error, :funding_not_live_and_held}
  end

  defp claim(state, key, stock_key, round, %{op: :reserve} = command, event_id, now) do
    {:ok, bound} = BindingRound.snapshot(round, now)

    put_in(state, [:stock_claims, Access.key(key)], %{
      reservation_id: command.reservation_id,
      terms_hash: bound.terms_hash,
      quantity: bound.contracted_quantity,
      stock_key: stock_key,
      event_id: event_id,
      admitted_at: now
    })
  end

  defp claim(state, _, _, _, _, _, _), do: state

  defp stock_for(gate, chapter, offer) do
    case gate.group_buys.stock_aggregates[stock_key(chapter, offer)] do
      nil -> InventoryCore.new(offer.seller, offer.sku, offer.unit)
      stock -> {:ok, stock}
    end
  end

  defp stock_key(chapter, offer),
    do: {chapter, offer.seller, offer.sku, offer.unit}

  defp seller_authorized(gate, chapter, seller, signers, now) do
    case {gate.group_buys.sellers[{chapter, seller}], signers} do
      {%{key_id: id, pubkey: pubkey, expires_at: expiry},
       [%{role: "group_seller", key_id: key_id, pubkey: signer_pubkey}]}
      when expiry > now and key_id == id and signer_pubkey == pubkey ->
        :ok

      _ ->
        {:error, :unauthorized_stock_seller}
    end
  end

  defp reference(value) when is_binary(value) and byte_size(value) in 1..256,
    do: if(String.trim(value) != "", do: :ok, else: {:error, :missing_stock_evidence})

  defp reference(_), do: {:error, :missing_stock_evidence}
end
