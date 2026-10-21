defmodule BizKit.Identity.Providers.Development do
  @moduledoc """
  Signs in as one configured person (`subject:`), with no real provider: the
  browser is sent straight back to the callback with that subject as the code.
  For local runs and end-to-end tests, one provider name per seeded person.

  It works only while `:biz_kit_identity, :allow_development_provider` is true.
  Development configuration sets it; no release configuration does, so a
  production deployment that named this provider would sign no one in.
  """
  @behaviour BizKit.Identity.Provider

  @issuer "biz-kit-development"

  @impl true
  def authorize_url(config, state, redirect_uri) do
    allowed?() || raise "the development identity provider is not allowed here"
    redirect_uri <> "?" <> URI.encode_query(code: config[:subject], state: state)
  end

  @impl true
  def authenticate(config, code, _redirect_uri) do
    cond do
      not allowed?() -> {:error, :development_provider_disallowed}
      code == config[:subject] -> {:ok, %{issuer: @issuer, subject: code}}
      true -> {:error, :rejected}
    end
  end

  defp allowed?, do: Application.get_env(:biz_kit_identity, :allow_development_provider) == true
end
