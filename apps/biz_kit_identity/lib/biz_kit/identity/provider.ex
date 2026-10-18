defmodule BizKit.Identity.Provider do
  @moduledoc """
  An authentication provider. It proves who signed in, as the OpenID Connect
  pair of issuer and subject; it decides nothing else. `config` is the keyword
  list configured for it under `:biz_kit_identity, :providers`.
  """

  @callback authorize_url(config :: keyword(), state :: String.t(), redirect_uri :: String.t()) ::
              String.t()

  @callback authenticate(config :: keyword(), code :: String.t(), redirect_uri :: String.t()) ::
              {:ok, BizKit.Identity.identity()} | {:error, term()}
end
