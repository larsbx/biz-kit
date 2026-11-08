defmodule ProcurementHost.Auth do
  @moduledoc "A single coordinator credential, not general identity/onboarding. Ledger grants are authoritative."
  import Plug.Conn
  alias CoopSubstrate.Procurement
  @lifetime 14_400_000

  def from_env! do
    seed = Base.decode16!(System.fetch_env!("PROCUREMENT_SIGNING_SEED_HEX"), case: :mixed)
    digest = Base.decode16!(System.fetch_env!("PROCUREMENT_LOGIN_SHA256"), case: :mixed)
    secret = System.fetch_env!("PROCUREMENT_SECRET_KEY_BASE")
    if byte_size(seed) != 32 or byte_size(digest) != 32 or byte_size(secret) < 64,
      do: raise("invalid procurement secret lengths")
    %{chapter_id: System.fetch_env!("PROCUREMENT_CHAPTER"),
      cooperative_id: System.fetch_env!("PROCUREMENT_COOPERATIVE"),
      operator_id: System.fetch_env!("PROCUREMENT_OPERATOR"),
      key_id: System.fetch_env!("PROCUREMENT_KEY_ID"), seed: seed,
      grant_version: String.to_integer(System.fetch_env!("PROCUREMENT_GRANT_VERSION")),
      login_digest: digest, secret_key_base: secret}
  end

  def settings, do: Application.fetch_env!(:procurement_host, :settings)
  def server, do: Application.get_env(:procurement_host, :log_server, CoopSubstrate.Log.server())

  def login(conn, token) when is_binary(token) and byte_size(token) in 43..256 do
    config = settings()
    if Plug.Crypto.secure_compare(:crypto.hash(:sha256, token), config.login_digest) do
      expires = Procurement.clock_ms() + @lifetime
      context = Map.put(config, :session_expires_at_ms, expires)
      case Procurement.snapshot(context, server()) do
        {:ok, _} ->
          Plug.CSRFProtection.delete_csrf_token()
          {:ok, conn |> clear_session() |> configure_session(renew: true)
            |> put_session("operator", %{ "grant" => config.grant_version,
              "expires" => expires, "credential" => Base.encode16(config.login_digest)})}
        _ -> {:error, :invalid_credentials}
      end
    else
      {:error, :invalid_credentials}
    end
  end
  def login(_, _), do: {:error, :invalid_credentials}

  def context(conn) do
    config = settings()
    case get_session(conn, "operator") do
      %{"grant" => grant, "expires" => expires, "credential" => credential}
          when is_integer(expires) ->
        if grant == config.grant_version and expires > Procurement.clock_ms() and
             credential == Base.encode16(config.login_digest),
          do: {:ok, Map.put(config, :session_expires_at_ms, expires)},
          else: {:error, :session_expired}
      _ -> {:error, :authentication_required}
    end
  end
end
