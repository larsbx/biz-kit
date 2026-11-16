defmodule ScfHost.Auth do
  @moduledoc """
  One accountant per deployment: a high-entropy console token and an optional
  API token, each configured only as a SHA-256 digest, and an independently
  granted server-held signing key. The ledger grant is authoritative: every
  sign-in, read and write is re-checked against it inside the Log.
  """
  import Plug.Conn
  alias CoopSubstrate.{Log, Scf}

  @session_ms 14_400_000
  @api_ms 300_000

  def from_env! do
    seed = hex!("SCF_SIGNING_SEED_HEX")
    login = hex!("SCF_LOGIN_SHA256")
    api = if System.get_env("SCF_API_SHA256") in [nil, ""], do: nil, else: hex!("SCF_API_SHA256")
    secret = System.fetch_env!("SCF_SECRET_KEY_BASE")

    if byte_size(seed) != 32 or byte_size(login) != 32 or (api && byte_size(api) != 32) or
         byte_size(secret) < 64,
       do: raise("invalid SCF secret lengths")

    %{
      chapter_id: System.fetch_env!("SCF_CHAPTER"),
      entity_id: System.fetch_env!("SCF_ENTITY"),
      accountant_id: System.fetch_env!("SCF_ACCOUNTANT"),
      key_id: System.fetch_env!("SCF_KEY_ID"),
      grant_version: String.to_integer(System.fetch_env!("SCF_GRANT_VERSION")),
      seed: seed,
      login_digest: login,
      api_digest: api,
      secret_key_base: secret
    }
  end

  defp hex!(name), do: Base.decode16!(System.fetch_env!(name), case: :mixed)

  def settings, do: Application.fetch_env!(:scf_host, :settings)
  def server, do: Application.get_env(:scf_host, :log_server, Log.server())

  @doc "Exchange the console token for a session, if the ledger grant is current."
  def login(conn, token) do
    config = settings()
    expires = Scf.clock_ms() + @session_ms

    with true <- matches?(token, config.login_digest),
         {:ok, _} <- Scf.book(context(config, expires), server()) do
      Plug.CSRFProtection.delete_csrf_token()

      {:ok,
       conn
       |> clear_session()
       |> configure_session(renew: true)
       |> put_session("accountant", %{
         "grant" => config.grant_version,
         "expires" => expires,
         "credential" => Base.encode16(config.login_digest)
       })}
    else
      _ -> {:error, :invalid_credentials}
    end
  end

  @doc "The signing context of a live console session."
  def session_context(conn) do
    config = settings()

    case get_session(conn, "accountant") do
      %{"grant" => grant, "expires" => expires, "credential" => credential}
      when is_integer(expires) ->
        if grant == config.grant_version and expires > Scf.clock_ms() and
             credential == Base.encode16(config.login_digest),
           do: {:ok, context(config, expires)},
           else: {:error, :session_expired}

      _ ->
        {:error, :authentication_required}
    end
  end

  @doc "The signing context of an API call (`Authorization: Bearer <token>`)."
  def api_context(conn) do
    config = settings()

    with %{api_digest: digest} when digest != nil <- config,
         ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         true <- matches?(token, digest) do
      {:ok, context(config, Scf.clock_ms() + @api_ms)}
    else
      _ -> {:error, :authentication_required}
    end
  end

  defp context(config, expires),
    do:
      config
      |> Map.take(~w(chapter_id entity_id accountant_id key_id seed grant_version)a)
      |> Map.put(:session_expires_at_ms, expires)

  defp matches?(token, digest) when is_binary(token) and byte_size(token) in 43..256,
    do: Plug.Crypto.secure_compare(:crypto.hash(:sha256, token), digest)

  defp matches?(_, _), do: false
end
