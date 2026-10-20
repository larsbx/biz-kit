defmodule Dispatch.Access.CapabilitySignerTest do
  @moduledoc """
  The capability document's signature, checked the way the client checks it:
  Ed25519 over the exact `CoopEventCanonicalV1` bytes served, then decoding.

  A test that only round-trips through the signer proves the signer agrees
  with itself, so these also pin what the client depends on — the schema
  name, canonical bytes, the `k-` key identifier — and that the published
  development seed is the one production refuses.
  """

  use ExUnit.Case, async: true

  alias CoopSubstrate.{Canonical, Crypto}
  alias Dispatch.Access.CapabilitySigner

  setup_all do
    {:ok, key} = CapabilitySigner.key()
    %{key: key}
  end

  defp signed(claims, key) do
    {:ok, signed} = CapabilitySigner.sign(claims, key)
    signed
  end

  test "a signed document verifies and yields its claims, schema included", %{key: key} do
    signed = signed(%{"features" => ["status"]}, key)

    assert {:ok, %{"features" => ["status"], "schema" => "DispatchCapabilityDocumentV1"}} =
             CapabilitySigner.verify(signed, key.public)

    assert signed.key_id == CapabilitySigner.key_id(key.public)
  end

  test "the served bytes are canonical, so the client verifies what it decodes", %{key: key} do
    signed = signed(%{"b" => 1, "a" => [true, "x"]}, key)
    bytes = Base.url_decode64!(signed.document, padding: false)

    assert {:ok, claims} = Canonical.decode(bytes)
    assert Canonical.encode!(claims) == bytes
    assert Crypto.verify(bytes, Base.url_decode64!(signed.signature, padding: false), key.public)
  end

  test "any altered part fails verification", %{key: key} do
    signed = signed(%{"features" => ["status"]}, key)

    {:ok, widened} =
      Canonical.encode(%{
        "features" => ["status", "approvals"],
        "schema" => CapabilitySigner.schema()
      })

    for tampered <- [
          %{signed | document: Base.url_encode64(widened, padding: false)},
          %{signed | signature: String.reverse(signed.signature)},
          %{signed | signature: "not base64!"},
          %{signed | document: "not base64!"}
        ] do
      assert {:error, :invalid_signature} = CapabilitySigner.verify(tampered, key.public)
    end
  end

  test "bytes signed under another schema are not a capability document", %{key: key} do
    # A ledger envelope or enrolment statement signed by the same key must not
    # verify as a document, whatever it contains.
    bytes = Canonical.encode!(%{"features" => ["status"], "schema" => "CoopDeviceEnrolmentV1"})

    forged = %{
      "document" => Base.url_encode64(bytes, padding: false),
      "signature" => Base.url_encode64(Crypto.sign(bytes, key.seed), padding: false)
    }

    assert {:error, :invalid_signature} = CapabilitySigner.verify(forged, key.public)
  end

  test "a document signed by another key does not verify", %{key: key} do
    {_public, seed} = Crypto.generate_keypair()
    {:ok, other} = CapabilitySigner.decode(Base.url_encode64(seed, padding: false))

    assert {:error, :invalid_signature} =
             CapabilitySigner.verify(signed(%{"features" => ["status"]}, other), key.public)
  end

  test "the configured test seed is the published development seed production refuses", %{
    key: key
  } do
    assert Base.url_encode64(key.public, padding: false) ==
             Dispatch.Config.development_capability_public()
  end

  test "a seed that is not 32 base64url bytes is refused" do
    for seed <- ["", "not base64!", Base.url_encode64(<<1, 2, 3>>, padding: false)] do
      assert {:error, :unreadable} = CapabilitySigner.decode(seed)
    end
  end
end
