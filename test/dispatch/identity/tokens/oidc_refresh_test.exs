defmodule Dispatch.Identity.Tokens.OidcRefreshTest do
  @moduledoc """
  Unknown key IDs must not turn an unauthenticated caller into a load generator
  against the issuer.

  Rotation needs a refresh when a `kid` is unknown — that is the whole mechanism
  by which a new signing key becomes usable without a restart. But a refresh per
  *request* means anyone can drive one outbound discovery call and one JWKS
  fetch, each with its own timeout, simply by inventing key IDs. Verification
  runs before any authentication has succeeded, so no token is needed to spend
  that.

  The concurrent test below is the one that matters. A cooldown kept as a
  timestamp in shared memory passes every sequential test and still fails under
  a burst, because the read, the check and the write are three steps and every
  caller can complete the first two before any completes the third.
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
      keys: %{"known" => JOSE.JWK.from_map(public)}
    })

    # The store carries the cooldown, so each test needs it in a known state.
    restart_key_store()

    on_exit(fn ->
      {issuer, audience} = previous
      Application.put_env(:dispatch, :oidc_issuer, issuer)
      Application.put_env(:dispatch, :oidc_audience, audience)
      :persistent_term.erase({Oidc, :jwks})
    end)

    %{private: private}
  end

  defp restart_key_store do
    Supervisor.terminate_child(Dispatch.Supervisor, Dispatch.Identity.Tokens.KeyStore)
    Supervisor.restart_child(Dispatch.Supervisor, Dispatch.Identity.Tokens.KeyStore)
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

  # Counts what the throttle exists to bound. The issuer is unreachable, so each
  # attempt is one discovery call that fails — and the telemetry it emits is a
  # faithful count of attempts made.
  defp count_discovery_attempts(fun) do
    parent = self()
    ref = make_ref()

    handler = fn _event, _measurements, _metadata, _config ->
      send(parent, {ref, :attempt})
    end

    :telemetry.attach({__MODULE__, ref}, [:dispatch, :oidc, :discovery], handler, nil)

    try do
      fun.()
      drain(ref, 0)
    after
      :telemetry.detach({__MODULE__, ref})
    end
  end

  defp drain(ref, count) do
    receive do
      {^ref, :attempt} -> drain(ref, count + 1)
    after
      200 -> count
    end
  end

  test "a burst of unknown key IDs costs one refresh, not one each", ctx do
    # The race this closes: every caller reads the cooldown as clear before any
    # has recorded an attempt, so every caller fetches. Sequential calls never
    # interleave that way, which is why a sequential test passed against the
    # broken version.
    attempts =
      count_discovery_attempts(fn ->
        1..20
        |> Task.async_stream(
          fn index -> Oidc.verify(token(ctx.private, "kid-#{index}")) end,
          max_concurrency: 20,
          timeout: 20_000
        )
        |> Stream.run()
      end)

    assert attempts == 1
  end

  test "a repeated unknown kid does not refetch", ctx do
    attempts =
      count_discovery_attempts(fn ->
        for _each <- 1..5, do: Oidc.verify(token(ctx.private, "unknown-kid"))
      end)

    assert attempts == 1
  end

  test "an unknown kid is refused", ctx do
    assert {:error, reason} = Oidc.verify(token(ctx.private, "unknown-kid"))
    assert reason in [:invalid_token, :unavailable]
  end

  test "a known kid still verifies while refreshes are suppressed", ctx do
    assert {:error, _reason} = Oidc.verify(token(ctx.private, "unknown-kid"))

    # Suppression must not become a denial of service of its own: keys already
    # cached need no coordination and keep working.
    assert {:ok, %{subject: "user-1"}} = Oidc.verify(token(ctx.private, "known"))
  end
end
