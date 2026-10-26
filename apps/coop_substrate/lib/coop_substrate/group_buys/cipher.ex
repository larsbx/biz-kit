defmodule CoopSubstrate.GroupBuys.Cipher do
  @moduledoc """
  Single-recipient private-offer packet: ephemeral X25519, HKDF-SHA256 and
  AES-256-GCM. The signed read request is authenticated associated data;
  plaintext retains the original seller-signed ledger offer envelope.
  This codec installs no ActivityPub, gossip or unauthenticated HTTP route.
  """
  alias CoopSubstrate.Canonical
  alias CoopSubstrate.Protocol.Envelope
  @domain "bizkit.private-group-buy-offer.v1"

  def seal(plaintext, recipient_key, request) do
    {public, private} = :crypto.generate_key(:ecdh, :x25519)
    shared = :crypto.compute_key(:ecdh, recipient_key, private, :x25519)
    salt = :crypto.strong_rand_bytes(32)
    nonce = :crypto.strong_rand_bytes(12)
    aad = associated_data(request)
    key = derive(shared, salt, aad)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, plaintext, aad, true)

    {:ok,
     %{
       schema: @domain,
       ephemeral_key: public,
       salt: salt,
       nonce: nonce,
       ciphertext: ciphertext,
       tag: tag
     }}
  end

  @doc "Recipient decrypts and then independently verifies the seller envelope and terms hash."
  def open(
        %{
          schema: @domain,
          ephemeral_key: <<_::256>> = public,
          salt: <<_::256>> = salt,
          nonce: <<_::96>> = nonce,
          ciphertext: ciphertext,
          tag: <<_::128>> = tag
        } = packet,
        private,
        request
      )
      when map_size(packet) == 6 and is_binary(ciphertext) do
    try do
      shared = :crypto.compute_key(:ecdh, public, private, :x25519)
      aad = associated_data(request)

      case :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             derive(shared, salt, aad),
             nonce,
             ciphertext,
             aad,
             tag,
             false
           ) do
        plaintext when is_binary(plaintext) -> {:ok, plaintext}
        _ -> {:error, :invalid_private_packet}
      end
    rescue
      _ -> {:error, :invalid_private_packet}
    end
  end

  def open(_, _, _), do: {:error, :invalid_private_packet}

  defp associated_data(request),
    do: Canonical.encode!(%{"domain" => @domain, "request" => Envelope.signed_core_term(request)})

  defp derive(shared, salt, aad) do
    prk = :crypto.mac(:hmac, :sha256, salt, shared)
    :crypto.mac(:hmac, :sha256, prk, @domain <> aad <> <<1>>)
  end
end
