defmodule GroupBuyCore do
  @moduledoc """
  Portable pure group-buy quotation and conditional commitment previews.

  A seller publishes a monetary cash price and explicitly funded volume
  discounts. Distinct buyers opt into a *possible* discounted purchase.
  Reaching a threshold is not sale acceptance, stock reservation, payment,
  company formation, escrow, or proof of shipment. All inputs require
  separate authenticated host checks before use.
  """

  @limit 9_007_199_254_740_991
  @offer_keys ~w(id seller sku unit currency revision expires_at capacity solo_unit_minor tiers)a
  @tier_keys ~w(min_quantity unit_minor)a
  @pledge_keys ~w(id buyer offer_id offer_revision quantity max_group_unit_minor expires_at)a
  @consent_keys ~w(actor quote_hash evidence_ref)a
  @schema "bizkit.group-buy.quote.v1"

  @doc """
  Return a deterministic quote for a seller-owned group campaign.

  Expired pledges are excluded, not silently resurrected or charged.
  A buyer may pledge interest without committing to purchase. Once valid,
  active pledges cover the seller's posted minimum volume, the group-price
  PURCHASE OPTION becomes visible for those members. No buyer must sign
  an advance purchase contract to unlock the option; no purchase or inventory
  reservation is implied. A seller-authorized host must still validate
  all pledge evidence, membership, available stock, price and checkout.
  """
  def quote(offer, pledges, now) when is_list(pledges) and is_integer(now) and now >= 0 do
    with :ok <- validate_offer(offer, now),
         :ok <- validate_pledges(offer, pledges) do
      active =
        pledges
        |> Enum.filter(&(&1.expires_at > now))
        |> Enum.sort_by(& &1.id)

      expired =
        pledges
        |> Enum.reject(&(&1.expires_at > now))
        |> Enum.map(& &1.id)
        |> Enum.sort()

      quantity = Enum.sum(Enum.map(active, & &1.quantity))

      cond do
        quantity > offer.capacity ->
          {:error, :oversubscribed}

        true ->
          unlocked =
            offer.tiers
            |> Enum.filter(&(&1.min_quantity <= quantity))
            |> List.last()

          with :ok <- price_ceiling(active, unlocked),
               {:ok, members} <- priced_members(active, offer, unlocked),
               {:ok, totals} <- totals(members, unlocked) do
            next_tier = Enum.find(offer.tiers, &(&1.min_quantity > quantity))

            expires_at =
              Enum.min([offer.expires_at | Enum.map(active, & &1.expires_at)])

            digest_fields =
              [@schema] ++
                offer_fields(offer) ++
                [Integer.to_string(length(active))] ++
                Enum.flat_map(active, &pledge_fields/1) ++
                [if(unlocked, do: Integer.to_string(unlocked.min_quantity), else: "none")]

            {:ok,
             %{
               schema: @schema,
               source_offer: offer,
               source_pledges: pledges,
               campaign_id: offer.id,
               seller: offer.seller,
               currency: offer.currency,
               sku: offer.sku,
               unit: offer.unit,
               members: members,
               active_quantity: quantity,
               expired_pledge_ids: expired,
               status:
                 if(unlocked,
                   do: :pledged_volume_covered_purchase_option_available,
                   else: :collecting_no_group_commitment
                 ),
               cash_unit_minor: offer.solo_unit_minor,
               group_unit_minor: if(unlocked, do: unlocked.unit_minor, else: nil),
               price_authority: :group_price_offer_requires_checkout_authorization,
               purchase_option_available: not is_nil(unlocked),
               coverage_basis: :active_member_pledges,
               contracted_quantity: 0,
               next_tier:
                 if(next_tier,
                   do: %{
                     minimum: next_tier.min_quantity,
                     more_units_needed: next_tier.min_quantity - quantity,
                     unit_minor: next_tier.unit_minor
                   },
                   else: nil
                 ),
               totals: totals,
               expires_at: expires_at,
               quote_hash: digest(digest_fields),
               payment_option: :independent_cash_checkout_always_available,
               group_option: :voluntary_conditional_group_purchase,
               contract_status: :not_admitted,
               inventory_status: :not_reserved,
               money_status: :not_collected
             }}
          end
      end
    end
  end

  def quote(_, _, _), do: {:error, :invalid_group_buy}

  @doc """
  Display a *buyer-specific* discounted purchase choice only after pledges
  cover the seller's posted quantity threshold. No advance purchase contract
  or unanimous member acceptance is necessary to display this option.

  The seller-home must authenticate the pledges and buyer membership before
  publishing the result privately, and revalidate exact inventory, rate,
  threshold and cash/payment authority at actual checkout. This function
  never grants purchasing authority, places a hold or collects money.
  """
  def purchase_option(quote, buyer, now) when is_binary(buyer) do
    with {:ok, verified} <- verify_quote(quote, now),
         :ok <- ready(verified),
         %{buyer: ^buyer} = member <- Enum.find(verified.members, &(&1.buyer == buyer)) do
      {:ok,
       %{
         kind: :group_purchase_option_preview,
         campaign_id: verified.campaign_id,
         quote_hash: verified.quote_hash,
         seller: verified.seller,
         buyer: buyer,
         pledge_id: member.pledge_id,
         sku: verified.sku,
         unit: verified.unit,
         quantity: member.quantity,
         currency: verified.currency,
         group_unit_minor: verified.group_unit_minor,
         discounted_total_minor: member.group_minor,
         ordinary_cash_total_minor: member.cash_minor,
         potential_savings_minor: member.savings_minor,
         volume_covered_by: :active_member_pledges,
         valid_until: verified.expires_at,
         checkout: :requires_fresh_membership_stock_and_payment_admission,
         paid: false,
         inventory_reserved: false
       }}
    else
      nil -> {:error, :buyer_not_in_pledges}
      {:error, _} = error -> error
      _ -> {:error, :invalid_group_purchase_option}
    end
  end

  def purchase_option(_, _, _), do: {:error, :invalid_group_purchase_option}

  @doc "Recheck the private pledge snapshot before displaying or using a purchase option."
  def verify_quote(%{source_offer: offer, source_pledges: pledges} = candidate, now) do
    case quote(offer, pledges, now) do
      {:ok, ^candidate} -> {:ok, candidate}
      _ -> {:error, :invalid_or_stale_quote}
    end
  end

  def verify_quote(_, _), do: {:error, :invalid_or_stale_quote}

  @doc """
  Optional all-party conditional agreement PREVIEW after pledged-volume
  eligibility. Matching evidence references here do not constitute verified
  signatures, seller acceptance, inventory reservation or a purchase.
  Showing a group purchase option does NOT require all buyers to contract
  or supply evidence here. Individual checkout is a separate host action.
  """
  def commitment_preview(quote, seller_consent, buyer_consents, now)
      when is_list(buyer_consents) do
    with {:ok, quote} <- verify_quote(quote, now),
         :ok <- ready(quote),
         :ok <- consent_shape(seller_consent, quote.seller, quote.quote_hash),
         :ok <- validate_buyers(buyer_consents, quote) do
      {:ok,
       %{
         quote_hash: quote.quote_hash,
         campaign_id: quote.campaign_id,
         expires_at: quote.expires_at,
         status: :requires_independent_local_business_admission,
         seller_evidence_ref: seller_consent.evidence_ref,
         commitments:
           Enum.map(quote.members, fn member ->
             evidence = Enum.find(buyer_consents, &(&1.actor == member.buyer))

             %{
               buyer: member.buyer,
               pledge_id: member.pledge_id,
               quantity: member.quantity,
               currency: quote.currency,
               conditional_group_minor: member.group_minor,
               full_cash_option_minor: member.cash_minor,
               evidence_ref: evidence.evidence_ref,
               state: :not_admitted
             }
           end),
         inventory_reserved: false,
         payment_authorized: false
       }}
    end
  end

  def commitment_preview(_, _, _, _), do: {:error, :invalid_consents}

  defp ready(%{
         status: :pledged_volume_covered_purchase_option_available,
         purchase_option_available: true,
         group_unit_minor: minor
       })
       when is_integer(minor) and minor > 0,
       do: :ok

  defp ready(_), do: {:error, :threshold_not_met}

  defp validate_buyers(consents, quote) do
    buyers = Enum.map(quote.members, & &1.buyer)

    supplied =
      Enum.map(consents, fn consent ->
        if is_map(consent), do: Map.get(consent, :actor), else: nil
      end)

    valid? =
      length(consents) == length(buyers) and
        Enum.sort(supplied) == Enum.sort(buyers) and
        Enum.all?(consents, fn consent ->
          consent_shape(consent, consent.actor, quote.quote_hash) == :ok
        end)

    if valid?, do: :ok, else: {:error, :invalid_consents}
  end

  defp consent_shape(%{} = consent, actor, hash) do
    if exact_keys?(consent, @consent_keys) and
         consent.actor == actor and
         consent.quote_hash == hash and
         is_binary(consent.evidence_ref) and
         byte_size(consent.evidence_ref) in 1..256 and
         String.trim(consent.evidence_ref) != "" do
      :ok
    else
      {:error, :invalid_consents}
    end
  end

  defp consent_shape(_, _, _), do: {:error, :invalid_consents}

  defp validate_offer(offer, now) when is_map(offer) do
    valid? =
      exact_keys?(offer, @offer_keys) and
        public_id?(offer.id) and public_id?(offer.seller) and
        URI.parse(offer.id).host == URI.parse(offer.seller).host and
        token?(offer.sku) and token?(offer.unit) and
        is_binary(offer.currency) and
        String.match?(offer.currency, ~r/\A[A-Z]{3}\z/) and
        bounded?(offer.revision, 0) and bounded?(offer.expires_at, 1) and
        offer.expires_at > now and bounded?(offer.capacity, 1) and
        bounded?(offer.solo_unit_minor, 1) and
        is_list(offer.tiers) and offer.tiers != [] and
        valid_tiers?(offer.tiers, offer.capacity, offer.solo_unit_minor)

    if valid?, do: :ok, else: {:error, :invalid_group_buy_offer}
  end

  defp validate_offer(_, _), do: {:error, :invalid_group_buy_offer}

  defp valid_tiers?(tiers, capacity, solo) do
    Enum.reduce_while(tiers, {0, solo}, fn tier, {previous_qty, previous_price} ->
      valid? =
        is_map(tier) and exact_keys?(tier, @tier_keys) and
          bounded?(tier.min_quantity, 1) and
          tier.min_quantity > previous_qty and tier.min_quantity <= capacity and
          bounded?(tier.unit_minor, 1) and tier.unit_minor < previous_price

      if valid?,
        do: {:cont, {tier.min_quantity, tier.unit_minor}},
        else: {:halt, :invalid}
    end) != :invalid
  end

  defp validate_pledges(offer, pledges) do
    valid? =
      Enum.all?(pledges, fn pledge -> valid_pledge?(pledge, offer) end)

    cond do
      not valid? ->
        {:error, :invalid_pledges}

      length(Enum.uniq_by(pledges, & &1.id)) != length(pledges) ->
        {:error, :duplicate_pledge}

      length(Enum.uniq_by(pledges, & &1.buyer)) != length(pledges) ->
        {:error, :duplicate_buyer}

      true ->
        :ok
    end
  end

  defp valid_pledge?(%{} = pledge, offer) do
    exact_keys?(pledge, @pledge_keys) and
      public_id?(pledge.id) and public_id?(pledge.buyer) and
      URI.parse(pledge.id).host == URI.parse(pledge.buyer).host and
      pledge.buyer != offer.seller and
      pledge.offer_id == offer.id and
      pledge.offer_revision == offer.revision and
      bounded?(pledge.quantity, 1) and
      bounded?(pledge.max_group_unit_minor, 1) and
      bounded?(pledge.expires_at, 1) and
      pledge.expires_at <= offer.expires_at
  end

  defp valid_pledge?(_, _), do: false

  defp price_ceiling(_pledges, nil), do: :ok

  defp price_ceiling(pledges, tier) do
    if Enum.all?(pledges, &(&1.max_group_unit_minor >= tier.unit_minor)),
      do: :ok,
      else: {:error, :buyer_price_limit_exceeded}
  end

  defp priced_members(pledges, offer, tier) do
    members =
      Enum.map(pledges, fn pledge ->
        cash = pledge.quantity * offer.solo_unit_minor
        group = if tier, do: pledge.quantity * tier.unit_minor, else: nil

        %{
          buyer: pledge.buyer,
          pledge_id: pledge.id,
          quantity: pledge.quantity,
          cash_minor: cash,
          group_minor: group,
          savings_minor: if(group, do: cash - group, else: nil),
          payment_options: [:pay_cash, :join_group],
          choice: :not_elected
        }
      end)

    if Enum.all?(members, fn member ->
         member.cash_minor <= @limit and
           (is_nil(member.group_minor) or member.group_minor <= @limit)
       end),
       do: {:ok, members},
       else: {:error, :amount_overflow}
  end

  defp totals(members, tier) do
    cash = Enum.sum(Enum.map(members, & &1.cash_minor))

    group =
      if not is_nil(tier),
        do: Enum.sum(Enum.map(members, & &1.group_minor)),
        else: nil

    if cash <= @limit and (is_nil(group) or group <= @limit) do
      {:ok,
       %{
         cash_minor: cash,
         group_minor: group,
         savings_minor: if(group, do: cash - group, else: nil)
       }}
    else
      {:error, :amount_overflow}
    end
  end

  defp offer_fields(offer) do
    [
      offer.id,
      offer.seller,
      offer.sku,
      offer.unit,
      offer.currency,
      Integer.to_string(offer.revision),
      Integer.to_string(offer.expires_at),
      Integer.to_string(offer.capacity),
      Integer.to_string(offer.solo_unit_minor),
      Integer.to_string(length(offer.tiers))
    ] ++
      Enum.flat_map(offer.tiers, fn tier ->
        [Integer.to_string(tier.min_quantity), Integer.to_string(tier.unit_minor)]
      end)
  end

  defp pledge_fields(pledge) do
    [
      pledge.id,
      pledge.buyer,
      pledge.offer_id,
      Integer.to_string(pledge.offer_revision),
      Integer.to_string(pledge.quantity),
      Integer.to_string(pledge.max_group_unit_minor),
      Integer.to_string(pledge.expires_at)
    ]
  end

  defp digest(fields) do
    payload =
      Enum.map_join(fields, "", fn text ->
        Integer.to_string(byte_size(text)) <> ":" <> text
      end)

    :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
  end

  defp exact_keys?(map, keys), do: Enum.sort(Map.keys(map)) == Enum.sort(keys)

  defp bounded?(value, minimum),
    do: is_integer(value) and value >= minimum and value <= @limit

  defp token?(value) when is_binary(value) and byte_size(value) in 1..128,
    do: String.match?(value, ~r/\A[a-z0-9][a-z0-9._:-]*\z/)

  defp token?(_), do: false

  # Syntactic shape only, never proof of seller/buyer identity or HTTPS safety.
  defp public_id?(value) when is_binary(value) and byte_size(value) <= 2048 do
    case URI.parse(value) do
      %URI{
        scheme: "https",
        host: host,
        path: path,
        query: nil,
        fragment: nil,
        userinfo: nil,
        port: port
      }
      when is_binary(host) and is_binary(path) and path != "" and port in [nil, 443] ->
        String.contains?(host, ".") and
          Regex.match?(~r/\A[a-z0-9.-]+\z/, String.downcase(host)) and
          not String.contains?(host, "..") and
          not String.ends_with?(host, ".local") and
          not String.ends_with?(host, ".internal") and
          match?({:error, _}, :inet.parse_address(String.to_charlist(host)))

      _ ->
        false
    end
  end

  defp public_id?(_), do: false
end
