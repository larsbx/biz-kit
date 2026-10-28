defmodule FederationService.SecurityTest do
  use ExUnit.Case, async: true
  alias FederationService.{Network, Signature, JSON}
  import FederationService.TestHelpers
  @actor "https://alpha.example/actors/shop"
  @url "https://beta.example/actors/shop/inbox"
  setup_all do
    key = key()
    %{key: key, identity: %{key_id: @actor <> "#main-key", key: Signature.public_key(key)}}
  end

  test "valid signed body and all covered components", c do
    body = Jason.encode!(activity(metadata()))
    headers = Signature.sign(@url, @actor, c.key, body)
    assert :ok = Signature.verify("/actors/shop/inbox", "beta.example", headers, body, c.identity)

    for changed <- [body <> " ", String.replace(body, "Part", "Changed")] do
      assert {:error, :invalid_signature} =
               Signature.verify(
                 "/actors/shop/inbox",
                 "beta.example",
                 headers,
                 changed,
                 c.identity
               )
    end

    assert {:error, _} = Signature.verify("/other", "beta.example", headers, body, c.identity)

    assert {:error, _} =
             Signature.verify("/actors/shop/inbox", "other.example", headers, body, c.identity)

    for h <- ~w(host date digest content-type signature) do
      assert {:error, _} =
               Signature.verify(
                 "/actors/shop/inbox",
                 "beta.example",
                 Enum.reject(headers, fn {k, _} -> k == h end),
                 body,
                 c.identity
               )

      assert {:error, _} =
               Signature.verify(
                 "/actors/shop/inbox",
                 "beta.example",
                 headers ++ [{h, "duplicate"}],
                 body,
                 c.identity
               )
    end
  end

  test "old and future dates, substituted key and algorithm refused", c do
    body = "{}"

    for delta <- [-301, 301] do
      h = Signature.sign(@url, @actor, c.key, body, DateTime.add(DateTime.utc_now(), delta))

      assert {:error, _} =
               Signature.verify("/actors/shop/inbox", "beta.example", h, body, c.identity)
    end

    assert {:error, _} =
             Signature.verify(
               "/actors/shop/inbox",
               "beta.example",
               Signature.sign(@url, @actor, c.key, body),
               body,
               %{c.identity | key: Signature.public_key(key())}
             )

    h =
      Signature.sign(@url, @actor, c.key, body)
      |> Enum.map(fn {k, v} -> {k, String.replace(v, "rsa-sha256", "hs2019")} end)

    assert {:error, _} =
             Signature.verify("/actors/shop/inbox", "beta.example", h, body, c.identity)

    assert {:error, _} = Signature.validate_key({:RSAPublicKey, 123, 65537})
    assert {:error, _} = Signature.validate_key({:RSAPublicKey, 123, 3})
  end

  test "HTTPS URL policy refuses parser ambiguities and dangerous destinations" do
    for url <- [
          "http://a.example/x",
          "https://127.0.0.1/x",
          "https://[::1]/x",
          "https://a.example:444/x",
          "https://user@a.example/x",
          "https://a.example/x?redirect=y",
          "https://a.example/x#f",
          "https://a.example/%0d%0a",
          "https://a.example/x\r\nhost: evil.example",
          "https://a.local/x",
          "https://a.example./x",
          "https://2130706433/x",
          "https://a.example/../x"
        ] do
      # Dot segments cannot escape an origin, but are rejected to avoid route aliases.
      assert {:error, _} = Network.uri(url)
    end

    assert {:ok, _} = Network.uri("https://alpha.example/actors/shop")

    assert {:error, :origin_substitution} =
             Network.same_origin(@actor, "https://evil.example/key")
  end

  test "all DNS answers are vetted including IPv6 transitions and mixed sets" do
    for ip <- [
          {127, 0, 0, 1},
          {10, 1, 2, 3},
          {169, 254, 169, 254},
          {100, 64, 0, 1},
          {172, 16, 0, 1},
          {192, 168, 0, 1},
          {0, 0, 0, 0},
          {224, 0, 0, 1},
          {192, 0, 2, 1},
          {198, 18, 0, 1},
          {0, 0, 0, 0, 0, 0, 0, 1},
          {0, 0, 0, 0, 0, 65535, 0x7F00, 1},
          {0x64, 0xFF9B, 0, 0, 0, 0, 0x7F00, 1},
          {0x2002, 0x7F00, 1, 0, 0, 0, 0, 1},
          {0xFC00, 0, 0, 0, 0, 0, 0, 1},
          {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}
        ] do
      refute Network.public_ip?(ip)
      assert {:error, :private_address} = Network.validate_addresses([{8, 8, 8, 8}, ip])
    end

    assert {:ok, {8, 8, 8, 8}, 443} = Network.validate_addresses([{8, 8, 8, 8}])
    assert Network.public_ip?({0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111})
  end

  test "JSON size and structural depth are bounded" do
    assert {:error, _} = JSON.decode(String.duplicate("x", 65_537))

    assert {:error, _} =
             JSON.decode(
               "{\"x\":" <> String.duplicate("[", 17) <> "0" <> String.duplicate("]", 17) <> "}"
             )

    assert {:ok, %{"x" => "[[\\\""}} = JSON.decode(Jason.encode!(%{"x" => "[[\\\""}))
    assert {:error, _} = JSON.decode("[]")
    assert {:error, _} = JSON.decode(~s({"actor":"a","actor":"b"}))
    assert {:error, _} = JSON.decode(~s({"nested":{"a":1,"a":2}}))
  end
end
