defmodule BarterCore.PricedExchange do
  @moduledoc """
  Two voluntary payment choices for every proposed pooled barter shipment:
  pay the seller's exact monetary price, or consider an in-network exchange
  with the seller's explicitly funded price reduction and conditional netting.

  All numbers are bounded integer minor units; no FX, credit issuance, money
  custody, tax calculation or payment authorization is performed. The offers
  are host-authenticated seller declarations, NOT arbitrary public assertions.
  A quote is neither contract acceptance nor proof of funds.
  """

  alias BarterCore, as: B
  alias BarterCore.PooledClearing

  @schema "bizkit.barter.priced-exchange.v1"
  @maximum 9_007_199_254_740_991
  @offer_keys ~w(seller code unit currency cash_unit_minor network_discount_unit_minor revision valid_until)a

  @doc """
  Price *every* available supply line in the snapshot. Emit both cash and
  network alternatives for each shipment; the network path cannot be
  unilaterally elected. Every participant retains its cash-payment choice.

  Network discounts are seller-funded; the seller's receipts are reduced by
  exactly the purchaser's quoted saving. Members must negotiate compensation
  and expressly approve a new signed contract before any monetary netting.
  """
  def quote(plan, offers, now, opts \\ [])

  def quote(%{snapshot: snapshot} = plan, offers, now, opts)
      when is_list(offers) and is_integer(now) and now >= 0 do
    with {:ok, ^plan} <- PooledClearing.verify_plan(plan, now, opts),
         :ok <- validate_offers(offers, snapshot, now),
         {:ok, priced} <- price_legs(plan.transfers, offers),
         {:ok, balances} <- balance(priced) do
      canonical_offers = Enum.sort_by(offers, &{&1.seller, &1.code, &1.unit})
      expiry =
        case canonical_offers do
          [] -> nil
          _ -> Enum.min(Enum.map(canonical_offers, & &1.valid_until))
        end

      fields =
        [@schema, plan.terms_hash, Integer.to_string(length(canonical_offers))] ++
          Enum.flat_map(canonical_offers, &offer_fields/1)

      {:ok,
       %{
         schema: @schema,
         plan_hash: plan.terms_hash,
         cash_option: :direct_payment_to_original_supplier,
         network_option: :seller_discount_and_conditional_member_netting,
         choice: :not_elected_requires_explicit_member_consent,
         offers: canonical_offers,
         priced_transfers: priced,
         balances: balances,
         valid_until: expiry,
         quote_hash: B.digest(fields),
         incentive_funding: :seller_funded_reduction_only,
         payment_status: :not_authorized_or_collected,
         network_status: :opportunity_not_binding
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_price_quote}
    end
  end

  def quote(_, _, _, _), do: {:error, :invalid_price_quote}

  defp validate_offers(offers, members, now) do
    offered = Enum.map(offers, &key/1)
    required =
      for member <- members, asset <- member.supplies do
        {member.actor, asset.code, asset.unit}
      end

    revisions = Map.new(members, &{&1.actor, &1.revision})

    cond do
      not Enum.all?(offers, &valid_offer?(&1, now, revisions)) ->
        {:error, :invalid_price_offers}

      length(offered) != length(Enum.uniq(offered)) ->
        {:error, :duplicate_price_offer}

      Enum.sort(offered) != Enum.sort(required) ->
        {:error, :missing_or_unowned_price_offer}

      true ->
        :ok
    end
  end

  defp key(%{seller: seller, code: code, unit: unit}), do: {seller, code, unit}
  defp key(_), do: :invalid

  defp valid_offer?(%{} = offer, now, revisions) do
    with true <- Enum.sort(Map.keys(offer)) == Enum.sort(@offer_keys),
         true <- B.valid_public_id?(offer.seller),
         true <- token?(offer.code) and token?(offer.unit),
         true <- is_binary(offer.currency) and
                   String.match?(offer.currency, ~r/\A[A-Z]{3}\z/),
         true <- bounded?(offer.cash_unit_minor) and bounded?(offer.network_discount_unit_minor),
         true <- offer.network_discount_unit_minor <= offer.cash_unit_minor,
         true <- is_integer(offer.revision) and
                   Map.get(revisions, offer.seller) == offer.revision,
         true <- is_integer(offer.valid_until) and offer.valid_until > now do
      true
    else
      _ -> false
    end
  end

  defp valid_offer?(_, _, _), do: false

  defp token?(value) when is_binary(value) and byte_size(value) in 1..64,
    do: String.match?(value, ~r/\A[a-z0-9][a-z0-9._:-]*\z/)

  defp token?(_), do: false
  defp bounded?(value), do: is_integer(value) and value >= 0 and value <= @maximum

  defp offer_fields(o) do
    [
      o.seller,
      o.code,
      o.unit,
      o.currency,
      Integer.to_string(o.cash_unit_minor),
      Integer.to_string(o.network_discount_unit_minor),
      Integer.to_string(o.revision),
      Integer.to_string(o.valid_until)
    ]
  end

  defp price_legs(transfers, offers) do
    index = Map.new(offers, &{key(&1), &1})

    Enum.reduce_while(transfers, {:ok, []}, fn leg, {:ok, acc} ->
      offer = Map.fetch!(index, {leg.from, leg.asset.code, leg.asset.unit})
      units = leg.asset.quantity

      gross = units * offer.cash_unit_minor
      saving = units * offer.network_discount_unit_minor
      net = gross - saving

      if gross > @maximum do
        {:halt, {:error, :amount_overflow}}
      else
        priced = %{
          from: leg.from,
          to: leg.to,
          asset: leg.asset,
          currency: offer.currency,
          cash_minor: gross,
          network_minor: net,
          incentive_minor: saving,
          seller_price_revision: offer.revision,
          seller_price_expires_at: offer.valid_until,
          options: [:network_opportunity, :pay_cash],
          election: :requires_counterparty_approval
        }

        {:cont, {:ok, [priced | acc]}}
      end
    end)
    |> case do
      {:ok, priced} -> {:ok, Enum.reverse(priced)}
      error -> error
    end
  end

  defp balance(legs) do
    actors_currencies =
      legs
      |> Enum.flat_map(fn leg ->
        [{leg.from, leg.currency}, {leg.to, leg.currency}]
      end)
      |> Enum.uniq()
      |> Enum.sort()

    rows =
      Enum.map(actors_currencies, fn {actor, currency} ->
        outgoing = Enum.filter(legs, &(&1.from == actor and &1.currency == currency))
        incoming = Enum.filter(legs, &(&1.to == actor and &1.currency == currency))

        cash_receivable = Enum.sum(Enum.map(outgoing, & &1.cash_minor))
        cash_payable = Enum.sum(Enum.map(incoming, & &1.cash_minor))
        network_receivable = Enum.sum(Enum.map(outgoing, & &1.network_minor))
        network_payable = Enum.sum(Enum.map(incoming, & &1.network_minor))
        discount_granted = Enum.sum(Enum.map(outgoing, & &1.incentive_minor))
        savings_offered = Enum.sum(Enum.map(incoming, & &1.incentive_minor))
        balance = network_payable - network_receivable

        %{
          actor: actor,
          currency: currency,
          cash_receivable_minor: cash_receivable,
          cash_payable_minor: cash_payable,
          network_receivable_minor: network_receivable,
          network_payable_minor: network_payable,
          discount_granted_minor: discount_granted,
          savings_offered_minor: savings_offered,
          conditional_net_due_minor: max(balance, 0),
          conditional_net_receivable_minor: max(-balance, 0),
          status: :preview_not_ledger_entry
        }
      end)

    if Enum.all?(rows, fn row ->
         Enum.all?(
           [
             row.cash_receivable_minor,
             row.cash_payable_minor,
             row.network_receivable_minor,
             row.network_payable_minor,
             row.discount_granted_minor,
             row.savings_offered_minor,
             row.conditional_net_due_minor,
             row.conditional_net_receivable_minor
           ],
           &bounded?/1
         )
       end) do
      {:ok, rows}
    else
      {:error, :amount_overflow}
    end
  end
end
