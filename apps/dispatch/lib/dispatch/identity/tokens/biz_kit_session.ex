defmodule Dispatch.Identity.Tokens.BizKitSession do
  @moduledoc """
  Accepts a biz-kit session as the `/v1` bearer token
  (biz-kit docs/architecture/2026-10-21-native-sign-in.md).

  The field app signs in through biz-kit (`BizKit.Identity`, RFC 8252 with
  PKCE) and carries the resulting session as `Authorization: Bearer`. Here the
  session is looked up and its identity resolved again on every request, so
  logout, expiry, revoking the principal's sessions and removing the identity
  binding each end `/v1` access at once.

  The subject is the biz-kit principal (`prn_…`): a dispatch user acting
  through biz-kit is registered with that principal as its `oidc_subject`.
  Nothing is matched on email or any provider attribute, as in biz-kit.

  Selected with `TOKEN_VERIFIER_ADAPTER=Dispatch.Identity.Tokens.BizKitSession`.
  """

  @behaviour Dispatch.Identity.Tokens.Verifier

  @issuer "biz-kit"

  @impl Dispatch.Identity.Tokens.Verifier
  def verify(token) when is_binary(token) and token != "" do
    case BizKit.Identity.session(token) do
      {:ok, %{principal: principal, expires_at: expires_at}} ->
        {:ok,
         %{
           subject: principal,
           issuer: @issuer,
           audience: [@issuer],
           expires_at: DateTime.from_unix!(expires_at, :millisecond)
         }}

      {:error, :expired} ->
        {:error, :expired}

      {:error, _unknown_or_unbound} ->
        {:error, :invalid_token}
    end
  end

  def verify(_token), do: {:error, :invalid_token}
end
