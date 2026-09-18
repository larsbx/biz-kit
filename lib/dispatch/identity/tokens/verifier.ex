defmodule Dispatch.Identity.Tokens.Verifier do
  @moduledoc """
  Validates an OIDC access token and returns its claims.

  Section 23.1 has clients perform Authorization Code with PKCE against a
  configurable standards-compliant provider. This service is a resource server:
  it never runs that flow, it validates the token that results from it.

  A behaviour rather than a single implementation, because a test must be able
  to mint a token without an identity provider and a deployment must not be able
  to use that shortcut. The production implementation fetches the issuer's JWKS;
  the test one accepts a locally signed token and is selectable only in test
  configuration.
  """

  @typedoc "Claims a verified token carried."
  @type claims :: %{
          required(:subject) => String.t(),
          required(:issuer) => String.t(),
          required(:audience) => [String.t()],
          required(:expires_at) => DateTime.t(),
          optional(:email) => String.t() | nil,
          optional(:name) => String.t() | nil
        }

  @typedoc """
  Why a token was refused.

  Deliberately coarse. Section 24.7 requires stable, non-sensitive reason codes,
  and telling a caller whether a token was merely expired or was signed by the
  wrong key helps an attacker more than a client.
  """
  @type reason :: :invalid_token | :expired | :untrusted_issuer | :wrong_audience | :unavailable

  @callback verify(token :: String.t()) :: {:ok, claims()} | {:error, reason()}

  @doc "Verifies a token with the configured implementation."
  @spec verify(String.t()) :: {:ok, claims()} | {:error, reason()}
  def verify(token) when is_binary(token), do: impl().verify(token)
  def verify(_token), do: {:error, :invalid_token}

  @doc """
  The configured implementation.

  Read through `Dispatch.Integrations.AdapterRegistry` like every other port, so
  the Section 31 startup validation that refuses a development-only adapter in
  production covers this selection too rather than having to know about it
  separately.
  """
  @spec impl() :: module()
  def impl do
    Dispatch.Integrations.AdapterRegistry.selected(:token_verifier)
  end
end
