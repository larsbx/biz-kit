defmodule BizKit.MarketingBridge do
  @moduledoc """
  Pre-admission composition of SalesCore consent and MarketingCore attribution.

  The host supplies an independently *verified* delivery-receipt binding in
  trusted context, then this pure policy ensures that it matches the proposed
  receipt and the current consent projection. Caller-constructed trusted
  context or source data is **never** an authorization or evidence of delivery.

  A successful result is an unsigned, source-attributed *candidate*, never
  a campaign send, opt-in grant, paid commission, or authoritative event.
  The host must recheck current grants/consent, validate signatures and
  receipt delivery, and serialize admission at actual commit time.
  """

  alias MarketingCore.Attribution
  alias SalesCore.Consent

  @receipt_fields [
    :tenant,
    :party_ref,
    :campaign_id,
    :channel,
    :jurisdiction,
    :audience,
    :delivery_status,
    :delivery_receipt_id,
    :delivery_receipt_digest,
    :delivered_at
  ]

  @doc """
  Preview attribution for a verified delivery followed by a visit.

  A receipt has opaque tenant/party/campaign/notification IDs, a receipt
  digest, consent channel and jurisdiction, delivery timestamps and a
  delivery status. The trusted host context must bind *the same* tenant,
  party, campaign, exact verified receipt bytes/fields and digest, and expected
  consent projection revision. Caller-provided delivery timestamps, audience,
  channel and attribution history must not override verified host evidence. This function performs no cryptographic
  verification and must not receive a trusted context from a public caller.
  """
  def preview(consent, receipt, %DateTime{} = check_in_at, window, trusted)
      when is_map(consent) and is_map(receipt) and is_map(trusted) and
             is_integer(window) and window >= 0 do
    with :ok <- bind(consent, receipt, trusted),
         :ok <- verified_receipt(receipt, trusted),
         :ok <- eligible_consent(consent, receipt),
         true <- Attribution.eligible?(receipt, check_in_at, window) do
      {:ok,
       %{
         kind: :unsigned_attribution_candidate,
         merchant: trusted.tenant,
         party_ref: trusted.party_ref,
         campaign_id: trusted.campaign_id,
         delivery_receipt_id: receipt.delivery_receipt_id,
         delivery_receipt_digest: receipt.delivery_receipt_digest,
         consent_version: consent.version,
         delivered_at: receipt.delivered_at,
         checked_in_at: check_in_at
       }}
    else
      false -> {:error, :not_attributable}
      {:error, _} = error -> error
    end
  end

  def preview(_, _, _, _, _), do: {:error, :invalid_attribution_proposal}

  defp bind(consent, receipt, trusted) do
    keys = [:tenant, :party_ref, :campaign_id]

    cond do
      not Enum.all?(keys, fn key ->
        valid_ref?(Map.get(trusted, key)) and
            Map.get(receipt, key) === Map.get(trusted, key)
      end) ->
        {:error, :wrong_attribution_scope}

      Map.get(consent, :tenant) !== trusted.tenant ->
        {:error, :wrong_attribution_scope}

      not (is_integer(Map.get(consent, :version)) and consent.version >= 0 and
               Map.get(trusted, :consent_version) === consent.version) ->
        {:error, :stale_consent_version}

      true ->
        :ok
    end
  end

  defp verified_receipt(receipt, trusted) do
    proof = Map.get(trusted, :verified_delivery_receipt)
    body = if is_map(proof), do: Map.get(proof, :body), else: nil
    prior = Map.get(trusted, :last_attributed_at)

    fields_match? =
      is_map(body) and
        Enum.sort(Map.keys(body)) == Enum.sort(@receipt_fields) and
        Map.take(receipt, @receipt_fields) === body

    receipt_shape? =
      Enum.sort(Map.keys(receipt)) in [
        Enum.sort(@receipt_fields),
        Enum.sort([:last_attributed_at | @receipt_fields])
      ]

    if fields_match? and receipt_shape? and
         valid_ref?(Map.get(receipt, :delivery_receipt_id)) and
         valid_ref?(Map.get(receipt, :delivery_receipt_digest)) and
         Map.get(proof, :id) === receipt.delivery_receipt_id and
         Map.get(proof, :digest) === receipt.delivery_receipt_digest and
         Map.get(receipt, :delivery_status) === :confirmed and
         Map.get(receipt, :last_attributed_at) === prior and
         (is_nil(prior) or match?(%DateTime{}, prior)) do
      :ok
    else
      {:error, :unverified_delivery_receipt}
    end
  end

  defp eligible_consent(consent, receipt) do
    if Consent.allowed?(
         consent,
         receipt.tenant,
         receipt.party_ref,
         Map.get(receipt, :channel),
         Map.get(receipt, :jurisdiction),
         Map.get(receipt, :audience)
       ) do
      :ok
    else
      {:error, :no_current_marketing_consent}
    end
  end

  defp valid_ref?(ref), do: is_binary(ref) and byte_size(ref) in 1..128
end
