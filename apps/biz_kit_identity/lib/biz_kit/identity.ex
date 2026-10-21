defmodule BizKit.Identity do
  @moduledoc """
  Who a person is inside biz-kit, independent of how they signed in
  (docs/architecture/2026-10-18-identity.md).

      provider (WorkOS today)  →  verified {issuer, subject}
      resolver (bindings)      →  principal  prn_…
      session                  →  short-lived, revocable, local

  A provider only authenticates. The principal is biz-kit's own ID; the
  ledger's grants name it, and the ledger alone decides what it may do.
  Replacing the provider means binding the person's new `{issuer, subject}` to
  the same principal; grants, signing keys and history stay as they are.
  """

  alias BizKit.Identity.{NativeLogins, Resolver, Sessions}

  @type identity :: %{issuer: String.t(), subject: String.t()}

  @doc "The provider's sign-in page, carrying `state` back to `redirect_uri`."
  @spec authorize_url(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :unknown_provider}
  def authorize_url(provider, state, redirect_uri) do
    with {:ok, {module, config}} <- provider(provider),
         do: {:ok, module.authorize_url(config, state, redirect_uri)}
  end

  @doc "Authenticate a provider's code, resolve the principal, open a session."
  @spec login(String.t(), String.t(), String.t()) :: {:ok, Sessions.id()} | {:error, term()}
  def login(provider, code, redirect_uri) do
    with {:ok, principal, identity} <- authenticate(provider, code, redirect_uri),
         do: {:ok, Sessions.create(principal, identity)}
  end

  defp authenticate(provider, code, redirect_uri) do
    with {:ok, {module, config}} <- provider(provider),
         {:ok, identity} <- module.authenticate(config, code, redirect_uri),
         {:ok, principal} <- Resolver.resolve(identity),
         do: {:ok, principal, identity}
  end

  # -- native apps (docs/architecture/2026-10-21-native-sign-in.md) ----------

  @doc """
  Starts a native app's sign-in. Returns the request ID, which the caller
  passes to the provider as its `state`.
  """
  @spec native_begin(String.t(), String.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, atom()}
  def native_begin(provider, redirect_uri, challenge, method, state) do
    with {:ok, _provider} <- provider(provider),
         :ok <- NativeLogins.validate(redirect_uri, challenge, method, state) do
      {:ok,
       NativeLogins.put_request(%{
         provider: provider,
         redirect_uri: redirect_uri,
         challenge: challenge,
         state: state
       })}
    end
  end

  @doc "Whether `state` names a pending native sign-in (as opposed to a browser one)."
  @spec native_request?(String.t()) :: boolean()
  def native_request?(state) when is_binary(state), do: NativeLogins.request?(state)
  def native_request?(_state), do: false

  @doc """
  Finishes the provider half of a native sign-in and returns where to send the
  browser: the app's redirect URI with a one-time `code`, or with
  `error=access_denied` when the person could not be signed in. Either way the
  request is spent. The reason for a denial is returned for the log, never
  sent to the app.
  """
  @spec native_complete(String.t(), String.t(), String.t() | nil, String.t()) ::
          {:ok, String.t()} | {:denied, String.t(), term()} | {:error, :unknown_request}
  def native_complete(provider, request_id, code, redirect_uri) do
    with {:ok, %{provider: ^provider} = request} <- NativeLogins.take_request(request_id) do
      # No code: the person cancelled or the provider refused. Still a denial
      # the app must hear about, not a request left hanging.
      case if(is_binary(code),
             do: authenticate(provider, code, redirect_uri),
             else: {:error, :no_code}
           ) do
        {:ok, principal, identity} ->
          grant = %{
            principal: principal,
            identity: identity,
            challenge: request.challenge,
            redirect_uri: request.redirect_uri
          }

          {:ok, app_redirect(request, code: NativeLogins.put_code(grant))}

        {:error, reason} ->
          {:denied, app_redirect(request, error: "access_denied"), reason}
      end
    else
      _unknown_expired_or_other_provider -> {:error, :unknown_request}
    end
  end

  @doc """
  Exchanges a one-time code and its PKCE verifier for a session. The code is
  spent by this call whatever its outcome, and the identity is resolved again,
  so a binding removed since sign-in yields no session.
  """
  @spec native_exchange(String.t(), String.t(), String.t()) ::
          {:ok, Sessions.id(), pos_integer()} | {:error, :invalid_grant}
  def native_exchange(code, verifier, redirect_uri) do
    with {:ok, grant} <- NativeLogins.take_code(code),
         true <- grant.redirect_uri == redirect_uri,
         true <- NativeLogins.verifies?(verifier, grant.challenge),
         {:ok, principal} when principal == grant.principal <- Resolver.resolve(grant.identity) do
      {:ok, Sessions.create(principal, grant.identity), div(Sessions.ttl_ms(), 1000)}
    else
      _ -> {:error, :invalid_grant}
    end
  end

  defp app_redirect(%{redirect_uri: uri, state: state}, params) do
    query = URI.encode_query(Enum.reject(params ++ [state: state], &is_nil(elem(&1, 1))))
    uri <> if(String.contains?(uri, "?"), do: "&", else: "?") <> query
  end

  @doc """
  A live session. Its identity is resolved again on every use, so unbinding an
  identity ends its sessions at once.
  """
  @spec session(Sessions.id(), integer()) :: {:ok, Sessions.t()} | {:error, atom()}
  def session(id, now_ms \\ System.system_time(:millisecond)) do
    with {:ok, session} <- Sessions.fetch(id, now_ms) do
      case Resolver.resolve(session.identity) do
        {:ok, principal} when principal == session.principal ->
          {:ok, session}

        _ ->
          Sessions.revoke(id)
          {:error, :unbound}
      end
    end
  end

  defdelegate logout(id), to: Sessions, as: :revoke
  defdelegate revoke_principal(principal), to: Sessions
  defdelegate session_ttl_ms(), to: Sessions, as: :ttl_ms

  @doc false
  def provider_config(name), do: name |> fetch_provider!() |> elem(1)

  defp provider(name) do
    case Map.fetch(Application.get_env(:biz_kit_identity, :providers, %{}), name) do
      {:ok, provider} -> {:ok, provider}
      :error -> {:error, :unknown_provider}
    end
  end

  defp fetch_provider!(name) do
    {:ok, provider} = provider(name)
    provider
  end
end
