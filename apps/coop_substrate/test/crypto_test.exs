defmodule CoopSubstrate.CryptoTest do
  use ExUnit.Case, async: true

  alias CoopSubstrate.Crypto

  test "sign/verify roundtrip" do
    {pub, seed} = Crypto.generate_keypair()
    msg = "canonical bytes stand in here"
    sig = Crypto.sign(msg, seed)

    assert byte_size(sig) == 64
    assert Crypto.verify(msg, sig, pub)
    refute Crypto.verify(msg <> "x", sig, pub)
  end

  test "verification fails under a different key" do
    {_pub, seed} = Crypto.generate_keypair()
    {other_pub, _} = Crypto.generate_keypair()
    sig = Crypto.sign("msg", seed)

    refute Crypto.verify("msg", sig, other_pub)
  end

  test "malformed signature or key sizes verify as false, never raise" do
    {pub, seed} = Crypto.generate_keypair()
    sig = Crypto.sign("msg", seed)

    refute Crypto.verify("msg", <<0>>, pub)
    refute Crypto.verify("msg", sig, <<0>>)
  end

  test "pubkey_from_seed matches generate_key derivation" do
    {pub, seed} = Crypto.generate_keypair()
    assert Crypto.pubkey_from_seed(seed) == pub
  end

  test "RFC 8032 §7.1 TEST 3 known vector" do
    seed =
      Base.decode16!("c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7",
        case: :lower
      )

    pub =
      Base.decode16!("fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025",
        case: :lower
      )

    msg = <<0xAF, 0x82>>

    sig =
      Base.decode16!(
        "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a",
        case: :lower
      )

    assert Crypto.sign(msg, seed) == sig
    assert Crypto.verify(msg, sig, pub)
  end
end
