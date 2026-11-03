defmodule CoopSubstrate.GovernanceAuthorizationTest do
  use ExUnit.Case, async: true

  alias CoopSubstrate.Crypto
  alias CoopSubstrate.Governance.{Authorization, Read}

  @now 1_700_000_000_000

  defp request do
    %{
      method: "POST",
      path: "/api/device-grants/board-1",
      timestamp_ms: @now,
      nonce: String.duplicate("n", 16),
      key_id: "k-governance"
    }
  end

  test "the client codec round-trips and accepts field order and comma-containing keys" do
    r = request()
    signature = :binary.copy(<<7>>, 64)

    assert {:ok, ^r, ^signature} =
             Authorization.parse(Authorization.encode(r, signature), r.method, r.path)

    sig = Base.url_encode64(signature, padding: false)

    reordered =
      ~s(CoopGovernance sig="#{sig}", nonce="#{r.nonce}", key="#{r.key_id}", ts="#{@now}")

    assert {:ok, ^r, ^signature} = Authorization.parse(reordered, r.method, r.path)
    comma_key = %{r | key_id: "k,governance"}

    assert {:ok, ^comma_key, ^signature} =
             Authorization.parse(Authorization.encode(comma_key, signature), r.method, r.path)
  end

  test "duplicate, extra, malformed and truncated fields cannot reach authorization" do
    r = request()
    header = Authorization.encode(r, :binary.copy(<<7>>, 64))

    for bad <- [
          nil,
          "Bearer token",
          header <> ~s(, extra="value"),
          String.replace(header, ~s(nonce="#{r.nonce}"), ~s(key="other")),
          String.replace(header, ~s(ts="#{@now}"), ~s(ts="99999999999999999999999999999")),
          String.replace(header, ~s(ts="#{@now}"), ~s(ts="-1")),
          String.replace(header, ~s(ts="#{@now}"), ~s(ts="not-an-integer")),
          String.replace(header, ~r/sig="[^"]*"/, ~s(sig="AQ")),
          header <> " trailing-junk"
        ] do
      assert {:error, :malformed_authorization} = Authorization.parse(bad, r.method, r.path)
    end
  end

  test "invalid shapes and nonce bounds are rejected before canonical encoding" do
    signature = :binary.copy(<<7>>, 64)

    for invalid <- [
          nil,
          %{},
          %{request() | timestamp_ms: 9_223_372_036_854_775_808},
          %{request() | timestamp_ms: -1},
          %{request() | timestamp_ms: 1.5},
          %{request() | key_id: nil},
          %{request() | nonce: <<255>>}
        ] do
      assert {:error, :invalid_request} = Read.chapters(%{}, invalid, signature, @now)
    end

    assert {:error, :invalid_nonce} =
             Read.chapters(%{}, %{request() | nonce: "short"}, signature, @now)

    assert {:error, :invalid_request} = Read.chapters(%{}, request(), <<7>>, @now)
  end

  test "stale requests are refused before signature work; valid signatures remain chapter scoped" do
    {pubkey, seed} = Crypto.generate_keypair()
    r = request()
    signature = Crypto.sign(Read.signing_bytes(r), seed)

    assert {:error, :stale_request} =
             Read.chapters(%{}, %{r | timestamp_ms: @now - 120_000}, signature, @now)

    keys = %{{"chapter-a", "governance"} => %{r.key_id => pubkey}}
    assert {:ok, ["chapter-a"]} = Read.chapters(keys, r, signature, @now)

    assert {:error, :not_governance} =
             Read.chapters(keys, %{r | path: "/different-path"}, signature, @now)
  end
end
