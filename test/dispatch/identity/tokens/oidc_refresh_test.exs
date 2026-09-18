defmodule Dispatch.Identity.Tokens.OidcRefreshTest do
  @moduledoc """
  Unknown key IDs must not turn an unauthenticated caller into a load generator
  against the issuer.

  Rotation needs a refresh when a `kid` is unknown — that is the whole mechanism
  by which a new signing key becomes usable without a restart. But a refresh per
  *request* means anyone can drive one outbound discovery and one JWKS fetch,
  each with its own timeout, simply by inventing key IDs. The cost lands on the
  Finch pool and on the issuer, and no token is required to pay it.
  """

  use ExUnit.Case, async: false

  alias Dispatch.Identity.Tokens.Oidc

  @issuer "https://issuer.invalid"
  @audience "dispatch-api"

  setup do
    previous = {
      Application.get_env(:dispatch, :oidc_issuer),
      Application.get_env(:dispatch, :oidc_audience)
    }

    Application.put_env(:dispatch, :oidc_issuer, @issuer)
    Application.put_env(:dispatch, :oidc_audience, @audience)

    private = JOSE.JWK.generate_key({:rsa, 2048})
    {_meta, public} = JOSE.JWK.to_public_map(private)

    :persistent_term.put({Oidc, :jwks}, %{
      fetched_at: System.monotonic_time(:millisecond),
      keys: %{"known" => JOSE.JWK.from_map(public)},
      misses: %{},
      attempts: 0
    })

    on_exit(fn ->
      {issuer, audience} = previous
      Application.put_env(:dispatch, :oidc_issuer, issuer)
      Application.put_env(:dispatch, :oidc_audience, audience)
      :persistent_term.erase({Oidc, :jwks})
    end)

    %{private: private}
  end

  defp token(private, kid) do
    claims = %{
      "iss" => @issuer,
      "aud" => @audience,
      "sub" => "user-1",
      "exp" => DateTime.utc_now() |> DateTime.add(300, :second) |> DateTime.to_unix()
    }

    {_meta, compact} =
      private
      |> JOSE.JWT.sign(%{"alg" => "RS256", "kid" => kid}, claims)
      |> JOSE.JWS.compact()

    compact
  end

  test "a repeated unknown kid is refused from cache rather than refetched", ctx do
    assert {:error, _first} = Oidc.verify(token(ctx.private, "unknown-kid"))

    # The issuer is unreachable, so the first attempt records the miss. The
    # second must be answered from that record: if it refetched, this assertion
    # is the only thing standing between an attacker and one outbound request
    # per token they send.
    assert Oidc.recent_miss?("unknown-kid")

    assert {:error, :invalid_token} = Oidc.verify(token(ctx.private, "unknown-kid"))
  end

  test "distinct unknown kids do not each earn their own refresh", ctx do
    for index <- 1..5 do
      assert {:error, _reason} = Oidc.verify(token(ctx.private, "kid-#{index}"))
    end

    # The bound itself, counted. A refresh attempt is what is rate-limited, not
    # a particular key ID: an attacker rotating the invented `kid` would
    # otherwise sidestep a per-key-ID cache entirely, so five unknown IDs must
    # still cost one fetch.
    assert Oidc.refresh_attempts() == 1
    assert Oidc.refresh_suppressed?()
  end

  test "a known kid still verifies while refreshes are suppressed", ctx do
    assert {:error, _reason} = Oidc.verify(token(ctx.private, "unknown-kid"))

    # Suppression must not become a denial of service of its own: keys already
    # cached keep working.
    assert {:ok, %{subject: "user-1"}} = Oidc.verify(token(ctx.private, "known"))
  end
end
