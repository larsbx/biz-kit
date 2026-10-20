defmodule Dispatch.Access.CapabilitySigner do
  @moduledoc """
  Signs the capability document the field application enables features from
  (d-patch §23.2).

  The platform has one signature scheme and this uses it: Ed25519
  (`CoopSubstrate.Crypto`) over `CoopEventCanonicalV1` bytes
  (`CoopSubstrate.Canonical`), with the ledger's `k-` key identifiers. Nothing
  is signed or verified except canonical bytes, and the bytes travel as signed,
  so the client verifies exactly what it received rather than a re-encoding.

  The claims carry `"schema" => "DispatchCapabilityDocumentV1"` and no `type`,
  so a document is never mistaken for a ledger envelope or a command — the
  same separation `CoopDeviceEnrolmentV1` and `CoopFeedReadV1` rely on.

  This is a service attestation, not anyone's signature: it says what the
  dispatch service told this session it may be offered. It grants nothing, and
  every request the client makes is authorized again.

  The key is a 32-byte Ed25519 seed, `DISPATCH_CAPABILITY_SIGNING_SEED`
  (base64url), loaded at runtime like every other secret.
  """

  alias CoopSubstrate.{Canonical, Crypto}

  @typedoc "A loaded signing key."
  @type key :: %{seed: <<_::256>>, public: <<_::256>>, key_id: String.t()}

  @typedoc "A signed document as served: the canonical bytes, the signature, the key."
  @type signed :: %{document: String.t(), signature: String.t(), key_id: String.t()}

  @schema "DispatchCapabilityDocumentV1"

  @doc "The schema name every document carries."
  @spec schema() :: String.t()
  def schema, do: @schema

  @doc "Encodes `claims` canonically and signs the bytes."
  @spec sign(map(), key()) :: {:ok, signed()} | {:error, Canonical.reason()}
  def sign(claims, %{seed: seed, key_id: key_id}) when is_map(claims) do
    with {:ok, bytes} <- Canonical.encode(Map.put(claims, "schema", @schema)) do
      {:ok,
       %{
         document: encode64(bytes),
         signature: encode64(Crypto.sign(bytes, seed)),
         key_id: key_id
       }}
    end
  end

  @doc """
  Verifies a served document against `public` and returns its claims.

  The server never needs this in production; it exists so the tests check the
  same thing the client checks, rather than asserting on unverified output.
  """
  @spec verify(signed() | map(), <<_::256>>) :: {:ok, map()} | {:error, :invalid_signature}
  def verify(%{document: document, signature: signature}, public),
    do: verify(%{"document" => document, "signature" => signature}, public)

  def verify(%{"document" => document, "signature" => signature}, public) do
    with {:ok, bytes} <- decode64(document),
         {:ok, sig} <- decode64(signature),
         true <- Crypto.verify(bytes, sig, public),
         {:ok, %{"schema" => @schema} = claims} <- Canonical.decode(bytes) do
      {:ok, claims}
    else
      _invalid -> {:error, :invalid_signature}
    end
  end

  @doc "The configured signing key, or why there is none."
  @spec key() :: {:ok, key()} | {:error, :unconfigured | :unreadable}
  def key do
    case Application.get_env(:dispatch, :capability_signing_seed) do
      seed when is_binary(seed) and seed != "" -> decode(seed)
      _unset -> {:error, :unconfigured}
    end
  end

  @doc "Decodes a base64url Ed25519 seed into a key."
  @spec decode(String.t()) :: {:ok, key()} | {:error, :unreadable}
  def decode(encoded) when is_binary(encoded) do
    case decode64(encoded) do
      {:ok, <<_::256>> = seed} ->
        public = Crypto.pubkey_from_seed(seed)
        {:ok, %{seed: seed, public: public, key_id: key_id(public)}}

      _other ->
        {:error, :unreadable}
    end
  end

  @doc "The ledger's key identifier: `k-` and the public key's first four bytes in hex."
  @spec key_id(<<_::256>>) :: String.t()
  def key_id(<<prefix::binary-size(4), _rest::binary>>),
    do: "k-" <> Base.encode16(prefix, case: :lower)

  defp encode64(bytes), do: Base.url_encode64(bytes, padding: false)

  defp decode64(text) when is_binary(text), do: Base.url_decode64(text, padding: false)
  defp decode64(_other), do: :error
end
