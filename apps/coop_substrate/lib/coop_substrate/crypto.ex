defmodule CoopSubstrate.Crypto do
  @moduledoc """
  Ed25519 signing and verification via OTP `:crypto` (`:eddsa`/`:ed25519`).

  Every signature in the substrate is Ed25519 over `CoopEventCanonicalV1`
  bytes (SUBSTRATE.md §1.4); nothing signs or verifies non-canonical bytes.
  Key custody, rotation semantics, and checkpoint signing are Phase 1D —
  Phase 1A only needs sign/verify plus the boot self-test
  (`CoopSubstrate.SelfTest`).
  """

  @type pubkey :: <<_::256>>
  @type seed :: <<_::256>>
  @type signature :: <<_::512>>

  @doc "Generate an Ed25519 keypair; the private part is the 32-byte seed."
  @spec generate_keypair() :: {pubkey(), seed()}
  def generate_keypair do
    :crypto.generate_key(:eddsa, :ed25519)
  end

  @doc "Derive the public key from a 32-byte seed."
  @spec pubkey_from_seed(seed()) :: pubkey()
  def pubkey_from_seed(<<_::256>> = seed) do
    {pub, ^seed} = :crypto.generate_key(:eddsa, :ed25519, seed)
    pub
  end

  @spec sign(binary(), seed()) :: signature()
  def sign(message, <<_::256>> = seed) when is_binary(message) do
    :crypto.sign(:eddsa, :none, message, [seed, :ed25519])
  end

  @spec verify(binary(), signature(), pubkey()) :: boolean()
  def verify(message, <<_::512>> = signature, <<_::256>> = pubkey)
      when is_binary(message) do
    :crypto.verify(:eddsa, :none, message, signature, [pubkey, :ed25519])
  end

  def verify(message, signature, pubkey)
      when is_binary(message) and is_binary(signature) and is_binary(pubkey),
      do: false
end
