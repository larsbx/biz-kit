defmodule Dispatch.Identity.Tokens.OidcTest do
  @moduledoc """
  Token verification is the boundary the whole authorization model sits behind:
  every capability check downstream assumes the subject is real.

  These tests seed the key cache directly rather than reaching a live issuer,
  because what needs proving is which tokens are *refused* — and a test that had
  to contact an identity provider to prove it would be skipped the moment the
  network was unavailable, which is precisely when it matters least to skip it.
  """

  use ExUnit.Case, async: false

  alias Dispatch.Identity.Tokens.Oidc

  @issuer "https://issuer.invalid"
  @audience "dispatch-api"
  @kid "test-key"

  setup do
    previous = {
      Application.get_env(:dispatch, :oidc_issuer),
      Application.get_env(:dispatch, :oidc_audience)
    }

    Application.put_env(:dispatch, :oidc_issuer, @issuer)
    Application.put_env(:dispatch, :oidc_audience, @audience)

    private = JOSE.JWK.generate_key({:rsa, 2048})
    {_meta, public} = JOSE.JWK.to_public_map(private)

    cache(%{@kid => JOSE.JWK.from_map(public)})

    on_exit(fn ->
      {issuer, audience} = previous
      Application.put_env(:dispatch, :oidc_issuer, issuer)
      Application.put_env(:dispatch, :oidc_audience, audience)
      :persistent_term.erase({Oidc, :jwks})
    end)

    %{private: private}
  end

  defp cache(keys) do
    :persistent_term.put({Oidc, :jwks}, %{
      fetched_at: System.monotonic_time(:millisecond),
      keys: keys
    })
  end

  defp claims(overrides \\ %{}) do
    Map.merge(
      %{
        "iss" => @issuer,
        "aud" => @audience,
        "sub" => "user-1",
        "exp" => DateTime.utc_now() |> DateTime.add(300, :second) |> DateTime.to_unix()
      },
      overrides
    )
  end

  defp sign(key, claims, alg \\ "RS256", kid \\ @kid) do
    {_meta, token} =
      key
      |> JOSE.JWT.sign(%{"alg" => alg, "kid" => kid}, claims)
      |> JOSE.JWS.compact()

    token
  end

  test "accepts a correctly signed token from the configured issuer", ctx do
    assert {:ok, verified} = Oidc.verify(sign(ctx.private, claims()))

    assert verified.subject == "user-1"
    assert verified.issuer == @issuer
    assert @audience in verified.audience
  end

  test "refuses a token from another issuer", ctx do
    assert {:error, :untrusted_issuer} =
             Oidc.verify(sign(ctx.private, claims(%{"iss" => "https://elsewhere.invalid"})))
  end

  test "refuses a token minted for another audience", ctx do
    assert {:error, :wrong_audience} =
             Oidc.verify(sign(ctx.private, claims(%{"aud" => "some-other-api"})))
  end

  test "accepts an audience array containing this API", ctx do
    assert {:ok, %{subject: "user-1"}} =
             Oidc.verify(sign(ctx.private, claims(%{"aud" => ["other", @audience]})))
  end

  test "refuses an expired token", ctx do
    expired = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.to_unix()

    assert {:error, :expired} = Oidc.verify(sign(ctx.private, claims(%{"exp" => expired})))
  end

  test "refuses a token carrying no expiry at all", ctx do
    assert {:error, :invalid_token} =
             Oidc.verify(sign(ctx.private, Map.delete(claims(), "exp")))
  end

  test "refuses a token signed by a key the issuer does not publish", _ctx do
    other = JOSE.JWK.generate_key({:rsa, 2048})

    assert {:error, :invalid_token} = Oidc.verify(sign(other, claims()))
  end

  test "refuses a token whose kid is absent from the JWKS", ctx do
    # An unknown `kid` triggers exactly one refresh, which cannot reach this
    # fake issuer — so the refusal is the outcome either way.
    assert {:error, reason} = Oidc.verify(sign(ctx.private, claims(), "RS256", "unknown"))
    assert reason in [:invalid_token, :unavailable]
  end

  describe "algorithm confusion" do
    test "an HMAC token signed with the published key material is refused" do
      # The attack: treat the *public* key as an HMAC secret. Anyone can read a
      # JWKS, so accepting HS256 would turn the published key into a signing key
      # and let any reader mint a token for any subject.
      secret = JOSE.JWK.from_oct("published-key-material-used-as-a-secret")
      cache(%{@kid => secret})

      assert {:error, :invalid_token} = Oidc.verify(sign(secret, claims(), "HS256"))
    end

    test "an unsigned token is refused" do
      # Assembled by hand: JOSE refuses to *sign* with `alg: none`, which is the
      # right default but means only a hand-built token can prove that the
      # verifier refuses to *accept* one.
      unsecured =
        [
          %{"alg" => "none", "kid" => @kid},
          claims()
        ]
        |> Enum.map_join(".", &Base.url_encode64(Jason.encode!(&1), padding: false))
        |> Kernel.<>(".")

      assert {:error, :invalid_token} = Oidc.verify(unsecured)
    end
  end

  test "refuses anything that is not a JWS" do
    assert {:error, :invalid_token} = Oidc.verify("not-a-token")
    assert {:error, :invalid_token} = Oidc.verify("")
    assert {:error, :invalid_token} = Oidc.verify(nil)
  end
end
