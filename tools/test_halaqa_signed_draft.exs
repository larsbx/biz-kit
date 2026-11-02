Code.require_file("halaqa_signed_draft.exs", __DIR__)
{:ok, _} = Application.ensure_all_started(:crypto)
ExUnit.start()

defmodule HalaqaSignedDraftTest do
  use ExUnit.Case, async: true
  @corpus Path.join(__DIR__, "halaqa_federation_draft/signed-vectors.json")

  defp fixture do
    first = @corpus |> File.read!() |> :json.decode() |> Map.fetch!("vectors") |> hd()
    {Base.decode64!(first["wire_base64"]), first["test_policy"]}
  end

  test "independent Elixir agrees on every refusal and verified transcript byte" do
    result = HalaqaSignedDraft.check_corpus(@corpus)

    assert result["counts"] == %{
             "SIGNATURE_VALID_AUTHORITY_UNVERIFIED" => 8,
             "REFUSED_SIGNED_TEST" => 66
           }

    refute result["authority_verified"]
    refute result["production_receiver"]
  end

  test "stateless signature success never claims replay consumption" do
    {wire, policy} = fixture()
    assert {:ok, first} = HalaqaSignedDraft.verify(wire, policy)
    assert {:ok, ^first} = HalaqaSignedDraft.verify(wire, policy)
    refute first.authority_verified
    refute first.production_receiver
  end

  test "a signature-valid TEST pin cannot authorize another recipient" do
    {wire, policy} = fixture()

    assert {:error, "test_context"} =
             HalaqaSignedDraft.verify(wire, Map.put(policy, "recipient", "other"))
  end

  test "revoke and expiry are explicit local TEST inputs" do
    {wire, policy} = fixture()

    assert {:error, "test_key_revoked"} =
             HalaqaSignedDraft.verify(wire, Map.put(policy, "revoked", true))

    assert {:error, "test_expiry"} =
             HalaqaSignedDraft.verify(wire, Map.put(policy, "now", 1_700_000_300))
  end

  test "numeric and boolean policy confusion fails closed" do
    {wire, policy} = fixture()

    for {field, value} <- [{"epoch", true}, {"now", 1.0}, {"revoked", 0}] do
      assert {:error, "test_policy"} =
               HalaqaSignedDraft.verify(wire, Map.put(policy, field, value))
    end
  end

  test "duplicate outer keys and trailing JSON values cannot be normalized away" do
    {wire, policy} = fixture()
    duplicate = binary_part(wire, 0, byte_size(wire) - 1) <> ",\"key_id\":\"other\"}"
    assert {:error, "duplicate_key"} = HalaqaSignedDraft.verify(duplicate, policy)
    assert {:error, "invalid_json"} = HalaqaSignedDraft.verify(wire <> " {}", policy)
  end

  test "signature bypass changes the fixed expected corpus verdicts" do
    {wire, policy} = fixture()
    envelope = :json.decode(wire)
    forged = Map.put(envelope, "signature", Base.encode64(:binary.copy(<<0>>, 64)))

    assert {:error, "invalid_signature"} =
             HalaqaSignedDraft.verify(IO.iodata_to_binary(:json.encode(forged)), policy)
  end

  test "remote authorization or public key assertions remain unknown fields" do
    {wire, policy} = fixture()
    envelope = :json.decode(wire)

    for field <- ["authorized", "public_key", "policy"] do
      changed = IO.iodata_to_binary(:json.encode(Map.put(envelope, field, true)))
      assert {:error, "signed_fields"} = HalaqaSignedDraft.verify(changed, policy)
    end
  end
end
