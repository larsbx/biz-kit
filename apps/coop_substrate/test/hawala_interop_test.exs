defmodule CoopSubstrate.HawalaInteropTest do
  use ExUnit.Case, async: true

  alias CoopSubstrate.Canonical
  alias CoopSubstrate.Crypto
  alias CoopSubstrate.Protocol.Envelope

  @vectors_path Path.expand("vectors/hawala_identity_v1.json", __DIR__)
  @prefix <<"hawala-identity-core/v1", 0>>

  # hawala-core pins the same digest for its copy
  # (`crates/identity-core/test-vectors/bizkit_identity_v1.json`).
  # Change both copies and both pins together.
  @fixture_sha256 "5b1b9406b7d40d45d14756c5e058af13908a54d481d2c7675faed38ead44a990"

  test "the fixture matches the digest pinned in both repositories" do
    digest = :crypto.hash(:sha256, File.read!(@vectors_path))
    assert Base.encode16(digest, case: :lower) == @fixture_sha256
  end

  # Hawala's own signer and verifier. The ledger's `Crypto` refuses Hawala's
  # signing domain by design (see `CoopSubstrate.SigningDomainTest`).
  defp hawala_sign(message, seed), do: :crypto.sign(:eddsa, :none, message, [seed, :ed25519])

  defp hawala_verify(message, signature, pubkey),
    do: :crypto.verify(:eddsa, :none, message, signature, [pubkey, :ed25519])

  defp fixture(name) do
    document = @vectors_path |> File.read!() |> Jason.decode!()
    assert document["schema"] == "hawala-identity-core-interoperability-v1"

    Enum.find(document["vectors"], &(&1["name"] == name)) ||
      raise("missing Hawala identity interoperability vector: #{name}")
  end

  defp bytes(vector, key) do
    Base.decode16!(Map.fetch!(vector, key), case: :mixed)
  end

  defp signing_input(domain, parts) do
    IO.iodata_to_binary([
      @prefix,
      <<byte_size(domain)::32>>,
      domain
      | Enum.map(parts, fn part -> [<<byte_size(part)::32>>, part] end)
    ])
  end

  defp vector_input(%{"name" => "possession-challenge"} = v) do
    expiry = v["expires_at"]

    signing_input(v["domain"], [
      bytes(v, "public_key_hex"),
      bytes(v, "verifier_key_hex"),
      bytes(v, "nonce_hex"),
      v["purpose"],
      <<expiry::64>>
    ])
  end

  defp vector_input(%{"name" => "merchant-credential"} = v) do
    issued = v["issued_at"]
    expiry = v["expires_at"]

    signing_input(v["domain"], [
      bytes(v, "credential_id_hex"),
      bytes(v, "public_key_hex"),
      bytes(v, "subject_key_hex"),
      v["kind"],
      v["scope"],
      <<issued::64>>,
      <<expiry::64>>
    ])
  end

  test "Hawala challenge and credential signed bytes match the independent golden fixtures" do
    for name <- ["possession-challenge", "merchant-credential"] do
      vector = fixture(name)
      pubkey = bytes(vector, "public_key_hex")
      seed = bytes(vector, "seed_hex")
      message = bytes(vector, "message_hex")
      signature = bytes(vector, "signature_hex")

      assert Crypto.pubkey_from_seed(seed) == pubkey
      assert vector_input(vector) == message
      assert hawala_sign(message, seed) == signature
      assert hawala_verify(message, signature, pubkey)
      refute hawala_verify(message <> <<0>>, signature, pubkey)
      refute Crypto.verify(message, signature, pubkey)

      # ASCII `h` (0x68). Hawala's encoding is not CBOR, but read as a CBOR
      # initial byte this is a text-string head, never a map head (0xA0..0xBB).
      assert <<0x68, _::binary>> = message
      assert String.starts_with?(message, @prefix)
      refute :binary.first(message) in 0xA0..0xBB
    end

    challenge = fixture("possession-challenge")
    assert challenge["qr_payload"] == "hawala:id:v1:" <> challenge["public_key_hex"]
  end

  test "biz-kit envelope signing bytes remain canonical CBOR maps, disjoint from Hawala" do
    hawala = fixture("possession-challenge")
    seed = bytes(hawala, "seed_hex")
    pubkey = bytes(hawala, "public_key_hex")

    {:ok, envelope} =
      Envelope.new(%{
        event_id: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
        chapter_id: "interop-test",
        type: "TestProjectionEvent",
        payload: %{"note" => "domain separation", "amount_minor" => 1},
        signers: [%{role: "author", pubkey: pubkey, key_id: "shared"}],
        timestamp_ms: 1_720_000_000_000
      })

    assert {:ok, <<head, _::binary>> = signed_bytes} = Envelope.signing_bytes(envelope)
    assert head in 0xA0..0xBB
    assert {:ok, decoded} = Canonical.decode(signed_bytes)
    assert decoded == Envelope.signed_core_term(envelope)

    assert {:ok, signed} = Envelope.sign(envelope, "shared", seed)
    assert :ok = Envelope.verify(signed)
    hawala_message = bytes(hawala, "message_hex")
    hawala_signature = bytes(hawala, "signature_hex")

    refute signed_bytes == hawala_message
    refute hawala_verify(hawala_message, signed.sigs["shared"], pubkey)
    refute Crypto.verify(signed_bytes, hawala_signature, pubkey)
  end
end
