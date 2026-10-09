defmodule CoopSubstrate.SelfTest do
  @moduledoc """
  Boot-time cryptographic self-test (phase1a_plan step 3).

  Run by `CoopSubstrate.Application` before any child starts; a mismatch
  aborts boot. Checks, in order:

    1. OTP `:crypto` supports `:eddsa` (Ed25519).
    2. RFC 8032 §7.1 TEST 1: deterministic signing reproduces the known
       signature and it verifies.
    3. The committed `envelope-core` vector: the production NIF encoder
       reproduces the committed canonical bytes, their SHA-256 matches, and
       the committed Ed25519 signature verifies.

  The expected values are baked in at compile time from
  `test/vectors/canonical_v1_vectors.json`. Tests corrupt them through the
  `:self_test_overrides` application env (hex-string values); production
  never sets that key.
  """

  alias CoopSubstrate.Canonical
  alias CoopSubstrate.Crypto

  @vectors_path Path.expand("../../test/vectors/canonical_v1_vectors.json", __DIR__)
  @external_resource @vectors_path

  # RFC 8032 §7.1 TEST 1 (Ed25519, empty message).
  @rfc8032_seed Base.decode16!("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
                  case: :lower
                )
  @rfc8032_pub Base.decode16!("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
                 case: :lower
               )
  @rfc8032_msg <<>>
  @rfc8032_sig Base.decode16!(
                 "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b",
                 case: :lower
               )

  vectors_doc = JSON.decode!(File.read!(@vectors_path))

  envelope_vector =
    Enum.find(vectors_doc["vectors"], &(&1["name"] == "envelope-core")) ||
      raise "envelope-core vector missing from #{@vectors_path}"

  # Inverse of the JSON term representation in scripts/gen_vectors.exs.
  from_json = fn
    %{"__bytes__" => hex}, _self ->
      {:bytes, Base.decode16!(hex, case: :lower)}

    m, self when is_map(m) ->
      Map.new(m, fn {k, v} -> {k, self.(v, self)} end)

    l, self when is_list(l) ->
      Enum.map(l, &self.(&1, self))

    other, _self ->
      other
  end

  @envelope_term from_json.(envelope_vector["term"], from_json)
  @envelope_canonical_hex envelope_vector["canonical_hex"]
  @envelope_sha256_hex envelope_vector["sha256_hex"]
  @envelope_sig_hex envelope_vector["sig_hex"]
  @envelope_pubkey_hex vectors_doc["ed25519_pubkey_hex"]

  @spec run() :: :ok | {:error, term()}
  def run do
    overrides = Application.get_env(:coop_substrate, :self_test_overrides, [])

    with :ok <- check_eddsa_support(),
         :ok <- check_rfc8032(overrides),
         :ok <- check_envelope_vector(overrides) do
      :ok
    end
  end

  defp check_eddsa_support do
    if :eddsa in :crypto.supports(:public_keys) do
      :ok
    else
      {:error, :eddsa_unsupported}
    end
  end

  defp check_rfc8032(overrides) do
    expected_sig = hex_override(overrides, :rfc8032_sig_hex, @rfc8032_sig)

    cond do
      Crypto.sign(@rfc8032_msg, @rfc8032_seed) != expected_sig ->
        {:error, :rfc8032_sign_mismatch}

      not Crypto.verify(@rfc8032_msg, expected_sig, @rfc8032_pub) ->
        {:error, :rfc8032_verify_failed}

      true ->
        :ok
    end
  end

  defp check_envelope_vector(overrides) do
    expected_bytes =
      hex_override(overrides, :envelope_canonical_hex, decode(@envelope_canonical_hex))

    expected_digest = hex_override(overrides, :envelope_sha256_hex, decode(@envelope_sha256_hex))
    sig = hex_override(overrides, :envelope_sig_hex, decode(@envelope_sig_hex))
    pubkey = decode(@envelope_pubkey_hex)

    cond do
      Canonical.encode(@envelope_term) != {:ok, expected_bytes} ->
        {:error, :envelope_vector_encode_mismatch}

      :crypto.hash(:sha256, expected_bytes) != expected_digest ->
        {:error, :envelope_vector_hash_mismatch}

      not Crypto.verify(expected_bytes, sig, pubkey) ->
        {:error, :envelope_vector_sig_invalid}

      true ->
        :ok
    end
  end

  defp hex_override(overrides, key, default) do
    case Keyword.fetch(overrides, key) do
      {:ok, hex} -> decode(hex)
      :error -> default
    end
  end

  defp decode(hex), do: Base.decode16!(hex, case: :lower)
end
