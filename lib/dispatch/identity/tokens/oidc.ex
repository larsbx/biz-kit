defmodule Dispatch.Identity.Tokens.Oidc do
  @moduledoc """
  Verifies a bearer token against the configured OIDC issuer's published keys.

  This service is a resource server (Section 23.1): clients run Authorization
  Code with PKCE against the provider, and this module validates the token that
  results. It fetches the issuer's discovery document and JWKS, caches them, and
  checks signature, issuer, audience, and expiry.

  Every one of those is checked separately, because each alone is insufficient:
  a correctly signed token from a *different* issuer is a valid token that this
  service must still refuse, as is one minted for a different audience — which
  is the confused-deputy attack `OIDC_AUDIENCE` exists to stop.

  Keys are cached with a bounded lifetime rather than forever, so a rotated
  signing key is picked up without a restart.

  ## Refreshing without becoming an amplifier

  An unknown `kid` has to be able to force a refresh — that is the whole
  mechanism by which a rotated key becomes usable without a restart. Doing it
  once *per request* is the trap: verification runs before any authentication
  has succeeded, so anyone able to reach the endpoint could drive one discovery
  call and one JWKS fetch, each with its own timeout, simply by inventing key
  IDs. The cost lands on this service's connection pool and on the issuer, and
  no valid token is needed to spend it.

  So a refresh is not something a request performs.
  `Dispatch.Identity.Tokens.KeyStore` owns it: callers queue behind one process,
  the first refresh updates the cache, and the rest are answered from it. A
  cooldown there bounds how often a fetch can happen at all — and because it
  lives inside a single process rather than in a read-check-write over shared
  memory, a simultaneous burst cannot slip past it, which is precisely what a
  timestamp in `:persistent_term` could not promise.

  Cache *reads* stay here, on the calling process. Routing those through the
  store would serialise all token verification behind one mailbox, and a key
  already cached needs no coordination.
  """

  @behaviour Dispatch.Identity.Tokens.Verifier

  alias Dispatch.Identity.Tokens.{KeyStore, Verifier}

  require Logger

  @cache_ttl_ms :timer.minutes(10)
  @request_timeout_ms 5_000

  # Asymmetric only. Accepting an HMAC algorithm would make the published JWKS a
  # *signing* key, letting anyone who can read it mint tokens; `none` would
  # remove signing altogether. `verify_strict/3` is given this same list, so the
  # algorithm the token asks for can never widen what is accepted.
  @permitted_algorithms ~w(RS256 RS384 RS512 ES256 ES384 ES512)

  @impl Verifier
  def verify(token) do
    with {:ok, kid} <- key_id(token),
         {:ok, jwk} <- signing_key(kid),
         {true, payload, _jws} <- JOSE.JWT.verify_strict(jwk, @permitted_algorithms, token) do
      validate_claims(payload)
    else
      {:error, reason} -> {:error, reason}
      # A bad signature, or one made with an algorithm outside the list above.
      {false, _payload, _jws} -> {:error, :invalid_token}
    end
  rescue
    # JOSE raises rather than returns on some malformed input. A refusal is the
    # only safe reading of a token this function cannot parse, and a crash here
    # would surface as a 500 where a 401 is the honest answer.
    _malformed -> {:error, :invalid_token}
  end

  defp key_id(token) do
    case JOSE.JWT.peek_protected(token) |> JOSE.JWS.to_map() |> elem(1) do
      %{"kid" => kid} when is_binary(kid) -> {:ok, kid}
      _no_kid -> {:error, :invalid_token}
    end
  rescue
    # `peek_protected/1` raises on anything that is not a JWS.
    _malformed -> {:error, :invalid_token}
  end

  defp validate_claims(%JOSE.JWT{fields: fields}) do
    with {:ok, expires_at} <- expiry(fields),
         :ok <- unexpired(expires_at),
         :ok <- trusted_issuer(fields["iss"]),
         {:ok, audiences} <- intended_audience(fields["aud"]),
         subject when is_binary(subject) and subject != "" <- fields["sub"] do
      {:ok,
       %{
         subject: subject,
         issuer: fields["iss"],
         audience: audiences,
         expires_at: expires_at,
         email: fields["email"],
         name: fields["name"]
       }}
    else
      {:error, reason} -> {:error, reason}
      _missing_subject -> {:error, :invalid_token}
    end
  end

  defp expiry(%{"exp" => exp}) when is_integer(exp), do: DateTime.from_unix(exp)
  defp expiry(_fields), do: {:error, :invalid_token}

  defp unexpired(expires_at) do
    case DateTime.compare(DateTime.utc_now(), expires_at) do
      :lt -> :ok
      _at_or_past -> {:error, :expired}
    end
  end

  defp trusted_issuer(issuer) do
    if is_binary(issuer) and issuer == issuer_config(), do: :ok, else: {:error, :untrusted_issuer}
  end

  # `aud` is a string or an array of strings. Both shapes mean the same thing,
  # so both are normalised before the membership test rather than compared
  # against separately.
  defp intended_audience(aud) do
    audiences = List.wrap(aud)

    if Application.get_env(:dispatch, :oidc_audience) in audiences do
      {:ok, audiences}
    else
      {:error, :wrong_audience}
    end
  end

  # A cache hit answers without leaving this process. Only a miss goes to the
  # key store, which is the one place a refresh can be started from.
  defp signing_key(kid) do
    case cached_key(kid) do
      {:ok, jwk} -> {:ok, jwk}
      :error -> KeyStore.ensure(kid)
    end
  end

  @doc """
  The key for `kid` if the cache holds one and has not gone stale.

  Public so `Dispatch.Identity.Tokens.KeyStore` can re-check it after queueing:
  by the time a queued call is served, an earlier one may already have fetched
  the key it is asking for.
  """
  @spec cached_key(String.t()) :: {:ok, JOSE.JWK.t()} | :error
  def cached_key(kid) do
    case :persistent_term.get({__MODULE__, :jwks}, nil) do
      %{fetched_at: fetched_at, keys: keys} ->
        if System.monotonic_time(:millisecond) - fetched_at < @cache_ttl_ms,
          do: Map.fetch(keys, kid),
          else: :error

      _never_fetched ->
        :error
    end
  end

  @doc """
  Fetches the issuer's JWKS and replaces the cached keys.

  Public only for `Dispatch.Identity.Tokens.KeyStore`, which serialises calls to
  it. Calling this from a request path would reintroduce exactly the per-request
  fetch the store exists to prevent.
  """
  @spec refresh_keys() :: :ok | {:error, :unavailable}
  def refresh_keys do
    with {:ok, jwks_uri} <- discover_jwks_uri(),
         {:ok, %{"keys" => keys}} when is_list(keys) <- get_json(jwks_uri) do
      :persistent_term.put({__MODULE__, :jwks}, %{
        fetched_at: System.monotonic_time(:millisecond),
        keys: usable_keys(keys)
      })

      :ok
    else
      _unavailable -> {:error, :unavailable}
    end
  end

  # A JWKS may advertise encryption keys and algorithms this service does not
  # accept. Filtering here rather than at verification time means an issuer
  # cannot get a symmetric key into the cache at all.
  defp usable_keys(keys) do
    for %{"kid" => kid} = key <- keys,
        key["kty"] in ["RSA", "EC"],
        key["use"] in [nil, "sig"],
        key["alg"] in [nil | @permitted_algorithms],
        into: %{} do
      {kid, JOSE.JWK.from_map(key)}
    end
  end

  defp discover_jwks_uri do
    # Emitted per attempt, which is the quantity the key store's cooldown
    # bounds. A test can then assert that bound by counting, rather than by
    # asserting the mechanism that is supposed to produce it.
    :telemetry.execute([:dispatch, :oidc, :discovery], %{count: 1}, %{})

    case get_json(String.trim_trailing(issuer_config() || "", "/") <> discovery_path()) do
      {:ok, %{"jwks_uri" => uri}} when is_binary(uri) -> {:ok, uri}
      _unavailable -> {:error, :unavailable}
    end
  end

  defp discovery_path, do: "/.well-known/openid-configuration"

  defp issuer_config, do: Application.get_env(:dispatch, :oidc_issuer)

  # Certificate verification is not left to a default. `Dispatch.Finch` pins
  # `verify_peer` against CAStore's bundle in the supervision tree, because
  # these keys are the root of trust for every request this service accepts: an
  # unverified fetch would let anyone on the network path replace them.
  defp get_json(url) do
    :get
    |> Finch.build(url, [{"accept", "application/json"}])
    |> Finch.request(Dispatch.Finch,
      receive_timeout: @request_timeout_ms,
      pool_timeout: @request_timeout_ms
    )
    |> case do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        Jason.decode(body)

      other ->
        # The URL is issuer configuration, not caller input, so it is safe to
        # log; the response body is not logged in case it carries detail.
        Logger.warning("OIDC key discovery failed",
          event_name: "oidc.discovery.failed",
          reason: inspect(failure_reason(other))
        )

        {:error, :unavailable}
    end
  end

  defp failure_reason({:ok, %Finch.Response{status: status}}), do: {:http_status, status}
  defp failure_reason({:error, reason}), do: reason
end
