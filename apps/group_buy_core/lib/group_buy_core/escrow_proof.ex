defmodule GroupBuyCore.EscrowProof do
  @moduledoc """
  Cryptographic, strictly scoped **external custodian evidence ingress**.

  A trusted seller-home pins a provider's Ed25519 verification key and
  campaign-specific grant independently of the incoming report. The
  provider signs one canonical, domain-separated report covering the exact
  campaign, seller, offer revision, buyer, custody reference, money amounts,
  provider event identity and expiration. No public gossip, caller-supplied
  provider identity, string proof reference or signature-free callback is
  financial authority.

  `preview/5` verifies proof and constructs a pure Escrow.apply candidate.
  It does NOT persist seller-home events, validate the provider's regulatory
  qualification, reserve money, or transmit payment/refund instructions.
  A host MUST authenticate its own trusted grant, serialize accepted
  evidence and commit the result in the existing canonical signed ledger.
  """

  alias GroupBuyCore.Escrow

  @schema "bizkit.group-buy.provider-proof.v1"
  @domain "bizkit.group-buy.provider-proof.ed25519.v1:"
  @proof_keys ~w(schema provider_id key_id campaign_id seller offer_revision
                 issued_at expires_at event_ref payload signature)a
  @grant_keys ~w(provider_id key_id public_key active grant_expires_at
                 campaign_id seller)a
  @hold_keys ~w(op buyer pledge_id custody_ref currency amount_minor expires_at)a
  @reconfirm_keys @hold_keys ++ [:prior_funding_evidence_ref]
  @release_keys ~w(op buyer custody_ref settlement_ref delivery_proof_ref
                   seller_paid_minor buyer_refund_minor)a
  @refund_keys ~w(op buyer custody_ref refund_ref refund_minor reason resolution_ref)a
  @max 9_007_199_254_740_991
  @freshness_seconds 600

  @doc """
  Serialize *strictly shaped* report terms for signing by an authorized
  external provider and verification by the seller-home. The signature
  field is excluded, but EVERY financial/event/scope field is included.

  This length-tagged, lexically keyed format requires no floats,
  dynamic atom creation, canonical JSON assumptions, or ambiguous strings.
  """
  def signing_payload(%{} = proof) do
    with :ok <- proof_shape(proof) do
      keys =
        @proof_keys
        |> Enum.reject(&(&1 == :signature))
        |> Enum.sort()

      encoded =
        Enum.map(keys, fn key ->
          length_prefixed(Atom.to_string(key)) <> encode(Map.fetch!(proof, key))
        end)
        |> IO.iodata_to_binary()

      {:ok, @domain <> encoded}
    end
  end

  def signing_payload(_), do: {:error, :invalid_provider_proof}

  @doc """
  Verify a provider-signed report against a previously pinned seller-home
  grant, and run the matching pure escrow transition as a *candidate only*.

  The returned state and command are NOT authoritative until the host durably
  commits them. In particular, the host must verify the grant's provenance,
  outside-of-code provider status, and real custody conditions.
  """
  def preview(escrow, round, proof, grant, now)
      when is_integer(now) and now >= 0 do
    with :ok <- validate_grant(grant, escrow, round, now),
         {:ok, message} <- signing_payload(proof),
         :ok <- scope(proof, grant, escrow, now),
         :ok <- verify_ed25519(message, proof.signature, grant.public_key),
         {:ok, actor, command} <- command(escrow, proof, message),
         {:ok, candidate, disposition} <- Escrow.apply(escrow, round, actor, command, now) do
      {:ok,
       %{
         kind: :verified_provider_event_candidate,
         command: command,
         producer: actor,
         provider_proof_hash: hex_hash(message <> proof.signature),
         source_provider: grant.provider_id,
         source_key_id: grant.key_id,
         escrow_projection: candidate,
         disposition: disposition,
         authoritative: false,
         requires: :seller_home_signed_ledger_commit
       }}
    end
  end

  def preview(_, _, _, _, _), do: {:error, :invalid_provider_proof}

  defp proof_shape(proof) do
    valid =
      exact?(proof, @proof_keys) and
        proof.schema == @schema and
        identifier?(proof.provider_id) and
        identifier?(proof.key_id) and
        identifier?(proof.campaign_id) and
        identifier?(proof.seller) and
        bounded?(proof.offer_revision) and
        bounded?(proof.issued_at) and
        bounded?(proof.expires_at) and
        proof.expires_at > proof.issued_at and
        identifier?(proof.event_ref) and
        is_binary(proof.signature) and byte_size(proof.signature) == 64 and
        valid_event?(proof.payload)

    if valid, do: :ok, else: {:error, :invalid_provider_proof}
  end

  defp valid_event?(%{op: :hold_confirmed} = event) do
    exact?(event, @hold_keys) and
      identifiers?([event.buyer, event.pledge_id, event.custody_ref, event.currency]) and
      bounded?(event.amount_minor) and bounded?(event.expires_at)
  end

  defp valid_event?(%{op: :hold_reconfirmed} = event) do
    exact?(event, @reconfirm_keys) and
      identifiers?([
        event.buyer,
        event.pledge_id,
        event.custody_ref,
        event.currency,
        event.prior_funding_evidence_ref
      ]) and
      bounded?(event.amount_minor) and bounded?(event.expires_at)
  end

  defp valid_event?(%{op: :delivery_release_confirmed} = event) do
    exact?(event, @release_keys) and
      identifiers?([
        event.buyer,
        event.custody_ref,
        event.settlement_ref,
        event.delivery_proof_ref
      ]) and bounded?(event.seller_paid_minor) and bounded?(event.buyer_refund_minor)
  end

  defp valid_event?(%{op: :refund_confirmed} = event) do
    exact?(event, @refund_keys) and
      identifiers?([event.buyer, event.custody_ref, event.refund_ref]) and
      bounded?(event.refund_minor) and
      (event.reason == :threshold_failed or event.reason == :lawful_resolution) and
      (is_nil(event.resolution_ref) or identifier?(event.resolution_ref))
  end

  defp valid_event?(_), do: false

  defp validate_grant(%{} = grant, escrow, round, now) do
    valid =
      exact?(grant, @grant_keys) and
        grant.active == true and
        identifier?(grant.provider_id) and
        identifier?(grant.key_id) and
        is_binary(grant.public_key) and byte_size(grant.public_key) == 32 and
        bounded?(grant.grant_expires_at) and grant.grant_expires_at > now and
        grant.campaign_id == escrow.offer.id and
        grant.seller == escrow.offer.seller and
        escrow.offer == round.offer

    if valid, do: :ok, else: {:error, :untrusted_provider_grant}
  end

  defp validate_grant(_, _, _, _), do: {:error, :untrusted_provider_grant}

  defp scope(%{} = proof, grant, escrow, now) do
    valid =
      proof.provider_id == grant.provider_id and
        proof.key_id == grant.key_id and
        proof.campaign_id == escrow.offer.id and
        proof.seller == escrow.offer.seller and
        proof.offer_revision == escrow.offer.revision and
        proof.issued_at <= now and
        now - proof.issued_at <= @freshness_seconds and
        proof.expires_at > now and
        proof.expires_at <= grant.grant_expires_at

    if valid, do: :ok, else: {:error, :provider_proof_out_of_scope_or_stale}
  end

  defp scope(_, _, _, _), do: {:error, :provider_proof_out_of_scope_or_stale}

  defp command(escrow, proof, message) do
    source = {:custody_provider, proof.provider_id}

    id =
      hex_hash(
        "bizkit.group-buy.provider-event.v1:" <>
          length_prefixed(proof.provider_id) <>
          length_prefixed(proof.campaign_id) <>
          length_prefixed(proof.event_ref)
      )

    old = Map.get(escrow.seen, id)

    version =
      case old do
        {^source, %{expected_version: previous}} -> previous
        _ -> escrow.version
      end

    command =
      proof.payload
      |> Map.put(:provider_id, proof.provider_id)
      |> Map.put(:id, id)
      |> Map.put(:expected_version, version)
      |> Map.put(:evidence_ref, hex_hash(message <> proof.signature))

    {:ok, source, command}
  end

  defp verify_ed25519(message, signature, key) do
    try do
      if :crypto.verify(:eddsa, :none, message, signature, [key, :ed25519]),
        do: :ok,
        else: {:error, :invalid_provider_signature}
    rescue
      _ -> {:error, :invalid_provider_signature}
    catch
      _, _ -> {:error, :invalid_provider_signature}
    end
  end

  defp exact?(value, keys) when is_map(value),
    do: Enum.sort(Map.keys(value)) == Enum.sort(keys)

  defp exact?(_, _), do: false

  defp identifiers?(values), do: Enum.all?(values, &identifier?/1)

  defp identifier?(value) when is_binary(value) and byte_size(value) in 1..2048,
    do: String.trim(value) != ""

  defp identifier?(_), do: false
  defp bounded?(value), do: is_integer(value) and value >= 0 and value <= @max

  defp hex_hash(bytes),
    do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp length_prefixed(value), do: <<byte_size(value)::unsigned-big-32, value::binary>>

  defp encode(value) when is_binary(value),
    do: "s" <> length_prefixed(value)

  defp encode(value) when is_integer(value),
    do: "i" <> length_prefixed(Integer.to_string(value))

  defp encode(value) when is_atom(value) and not is_nil(value),
    do: "a" <> length_prefixed(Atom.to_string(value))

  defp encode(nil), do: "n"

  defp encode(%{} = fields) do
    sorted = Enum.sort_by(Map.to_list(fields), fn {key, _} -> Atom.to_string(key) end)

    body =
      Enum.map(sorted, fn {key, value} ->
        length_prefixed(Atom.to_string(key)) <> encode(value)
      end)
      |> IO.iodata_to_binary()

    "m" <> <<map_size(fields)::unsigned-big-32>> <> body
  end
end
