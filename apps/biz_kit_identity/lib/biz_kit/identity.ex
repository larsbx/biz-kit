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

  alias BizKit.Identity.{Resolver, Sessions}

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
    with {:ok, {module, config}} <- provider(provider),
         {:ok, identity} <- module.authenticate(config, code, redirect_uri),
         {:ok, principal} <- Resolver.resolve(identity) do
      {:ok, Sessions.create(principal, identity)}
    end
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
