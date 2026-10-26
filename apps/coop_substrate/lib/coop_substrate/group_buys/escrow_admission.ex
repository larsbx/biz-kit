defmodule CoopSubstrate.GroupBuys.EscrowAdmission do
  @moduledoc """
  Seller-home canonical-Log gate for *externally* custodied group-buy evidence.

  A seller-signed provider grant pins one Ed25519 key for one campaign.
  A later seller-signed admission embeds the original externally signed
  provider report (canonical CBOR). The appender verifies that report against
  the pinned grant, folds GroupBuyCore.Escrow, and enforces global provider
  event/custody nullifiers before the sole canonical ledger commits.

  The seller's self-signed provider grant is NOT evidence of provider
  licensing or real funds. Operational hosts must verify provider status and
  grant provenance externally. These events observe outside custody;
  they never request, move or hold money.
  """

  alias CoopSubstrate.Canonical
  alias GroupBuyCore.EscrowProof

  @proof_keys ~w(schema provider_id key_id campaign_id seller offer_revision issued_at
                 expires_at event_ref payload signature)
  @hold_keys ~w(op buyer pledge_id custody_ref currency amount_minor expires_at)
  @release_keys ~w(op buyer custody_ref settlement_ref delivery_proof_ref
                    seller_paid_minor buyer_refund_minor)
  @refund_keys ~w(op buyer custody_ref refund_ref refund_minor reason resolution_ref)

  @doc "Validate and project a seller-home pin or replacement of a provider key."
  def pin(%{chapter_id: chapter, payload: p, signers: signers, event_id: event_id}, gate, now) do
    key = campaign_key(chapter, p)
    id = {key, p["provider_id"]}
    previous = gate.group_buys.escrow_grants[id]

    with :ok <- seller_authority(chapter, p["seller_id"], signers, gate, now),
         :ok <- known_campaign(key, gate),
         :ok <- expected_version(previous, p["expected_version"]),
         true <- valid_id?(p["provider_id"]) and valid_id?(p["key_id"]),
         {:bytes, <<_::256>> = pubkey} <- p["pubkey"],
         true <-
           is_boolean(p["active"]) and
             is_integer(p["expires_at"]) and p["expires_at"] > now do
      pinned = %{
        provider_id: p["provider_id"],
        key_id: p["key_id"],
        public_key: pubkey,
        active: p["active"],
        grant_expires_at: p["expires_at"],
        campaign_id: p["campaign_id"],
        seller: p["seller_id"],
        authorization_event_id: event_id,
        version: p["expected_version"] + 1
      }

      {:ok, put_in(gate.group_buys, [:escrow_grants, Access.key(id)], pinned)}
    else
      _ -> {:error, :untrusted_or_stale_escrow_provider_pin}
    end
  end

  @doc """
  Independently verify the provider signature, replay the exact escrow
  reducer transition, and index event/custody references across ALL campaigns
  in the same canonical seller-home ledger.

  Called from Log's verify-on-append gate. The *entire* transition is a pure
  candidate until the canonical append completes. No second ledger exists.
  """
  def admit(%{chapter_id: chapter, payload: p, signers: signers, event_id: event_id}, gate, now) do
    key = campaign_key(chapter, p)

    with :ok <- seller_authority(chapter, p["seller_id"], signers, gate, now),
         :ok <- known_campaign(key, gate),
         {:ok, proof} <- decode_proof(p["proof"]),
         %{version: version} = escrow <- gate.group_buys.escrow_states[key],
         true <- p["expected_version"] == version,
         grant when not is_nil(grant) <-
           gate.group_buys.escrow_grants[{key, proof.provider_id}],
         :ok <- provider_global_event(gate, proof),
         :ok <- provider_custody(gate, key, proof),
         {:ok, candidate} <-
           EscrowProof.preview(
             escrow,
             gate.group_buys.rounds[key],
             proof,
             Map.take(grant, [
               :provider_id,
               :key_id,
               :public_key,
               :active,
               :grant_expires_at,
               :campaign_id,
               :seller
             ]),
             now
           ),
         true <- candidate.disposition == :accepted do
      state = gate.group_buys

      next =
        state
        |> put_in([:escrow_states, Access.key(key)], candidate.escrow_projection)
        |> put_in(
          [:escrow_provider_events, Access.key({proof.provider_id, proof.event_ref})],
          %{
            campaign_key: key,
            ledger_event_id: event_id,
            provider_proof_hash: candidate.provider_proof_hash
          }
        )
        |> add_custody_claim(key, proof)

      {:ok, next}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_escrow_evidence_admission}
    end
  end

  @doc "Strict canonical proof decoding: incoming CBOR maps have string keys."
  def decode_proof({:bytes, bytes}) when is_binary(bytes) do
    with {:ok, %{} = raw} <- Canonical.decode(bytes),
         true <- exact?(raw, @proof_keys),
         {:bytes, <<_::512>> = signature} <- raw["signature"],
         {:ok, payload} <- decode_payload(raw["payload"]) do
      {:ok,
       raw
       |> Map.drop(["payload", "signature"])
       |> atomize(@proof_keys -- ["payload", "signature"])
       |> Map.put(:payload, payload)
       |> Map.put(:signature, signature)}
    else
      _ -> {:error, :invalid_signed_provider_report}
    end
  end

  def decode_proof(_), do: {:error, :invalid_signed_provider_report}

  defp decode_payload(%{"op" => "hold_confirmed"} = raw),
    do: payload(raw, @hold_keys, :hold_confirmed)

  defp decode_payload(%{"op" => "delivery_release_confirmed"} = raw),
    do: payload(raw, @release_keys, :delivery_release_confirmed)

  defp decode_payload(%{"op" => "refund_confirmed"} = raw) do
    with {:ok, decoded} <- payload(raw, @refund_keys, :refund_confirmed),
         reason when reason in ["threshold_failed", "lawful_resolution"] <- raw["reason"] do
      {:ok, %{decoded | reason: String.to_existing_atom(reason)}}
    else
      _ -> {:error, :invalid_provider_event_shape}
    end
  end

  defp decode_payload(_), do: {:error, :invalid_provider_event_shape}

  defp payload(raw, keys, op) do
    if exact?(raw, keys),
      do: {:ok, raw |> Map.delete("op") |> atomize(keys -- ["op"]) |> Map.put(:op, op)},
      else: {:error, :invalid_provider_event_shape}
  end

  defp atomize(map, keys) do
    Map.new(keys, fn key ->
      {String.to_existing_atom(key), Map.fetch!(map, key)}
    end)
  end

  defp provider_global_event(gate, proof) do
    if Map.has_key?(
         gate.group_buys.escrow_provider_events,
         {proof.provider_id, proof.event_ref}
       ),
       do: {:error, :provider_event_already_admitted},
       else: :ok
  end

  defp provider_custody(gate, key, proof) do
    ident = {proof.provider_id, proof.payload.custody_ref}
    claim = gate.group_buys.escrow_custody_claims[ident]

    case {proof.payload.op, claim} do
      {:hold_confirmed, nil} ->
        :ok

      {:hold_confirmed, _} ->
        {:error, :cross_campaign_custody_reused}

      {_, %{campaign_key: ^key, buyer: buyer}}
      when buyer == proof.payload.buyer ->
        :ok

      _ ->
        {:error, :unowned_or_cross_campaign_custody}
    end
  end

  defp add_custody_claim(state, key, %{
         provider_id: provider_id,
         payload: %{op: :hold_confirmed} = body
       }) do
    put_in(state, [:escrow_custody_claims, Access.key({provider_id, body.custody_ref})], %{
      campaign_key: key,
      buyer: body.buyer
    })
  end

  defp add_custody_claim(state, _, _), do: state

  defp seller_authority(chapter, seller_id, signers, gate, now) do
    credential = gate.group_buys.sellers[{chapter, seller_id}]

    case {credential, signers} do
      {%{key_id: id, pubkey: pubkey, expires_at: expiry},
       [%{role: "group_seller", key_id: signer_id, pubkey: signer_pubkey}]}
      when expiry > now and id == signer_id and pubkey == signer_pubkey ->
        :ok

      _ ->
        {:error, :invalid_escrow_seller_authority}
    end
  end

  defp known_campaign(key, gate) do
    case {gate.group_buys.offers[key], gate.group_buys.rounds[key],
          gate.group_buys.escrow_states[key]} do
      {%{}, %{}, %{}} -> :ok
      _ -> {:error, :unknown_escrow_campaign}
    end
  end

  defp expected_version(nil, 0), do: :ok
  defp expected_version(%{version: value}, value), do: :ok
  defp expected_version(_, _), do: {:error, :stale_escrow_provider_pin}

  defp exact?(map, keys) when is_map(map), do: Enum.sort(Map.keys(map)) == Enum.sort(keys)
  defp exact?(_, _), do: false

  defp valid_id?(value),
    do:
      is_binary(value) and byte_size(value) in 1..256 and
        String.trim(value) != ""

  defp campaign_key(chapter, p), do: {chapter, p["seller_id"], p["campaign_id"]}
end
