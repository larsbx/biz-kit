defmodule BizKit.Identity.Providers.WorkOS do
  @moduledoc """
  WorkOS AuthKit. The browser signs in on AuthKit's hosted page; the code it
  returns is exchanged server-side, over TLS with the API key, for the WorkOS
  user. The issuer is the client's user-management URL, as in WorkOS access
  tokens, and the subject is the WorkOS user ID.

  Config: `client_id`, `api_key`, optionally `base_url` and `req_options`.
  """

  @behaviour BizKit.Identity.Provider

  @base_url "https://api.workos.com"

  @impl true
  def authorize_url(config, state, redirect_uri) do
    query =
      URI.encode_query(%{
        "client_id" => config[:client_id],
        "redirect_uri" => redirect_uri,
        "response_type" => "code",
        "provider" => "authkit",
        "state" => state
      })

    base_url(config) <> "/user_management/authorize?" <> query
  end

  @impl true
  def authenticate(config, code, _redirect_uri) do
    request =
      Req.new(
        [
          method: :post,
          url: base_url(config) <> "/user_management/authenticate",
          json: %{
            "client_id" => config[:client_id],
            "client_secret" => config[:api_key],
            "grant_type" => "authorization_code",
            "code" => code
          }
        ] ++ Keyword.get(config, :req_options, [])
      )

    case Req.request(request) do
      {:ok, %{status: 200, body: %{"user" => %{"id" => id}}}} when is_binary(id) and id != "" ->
        {:ok,
         %{issuer: base_url(config) <> "/user_management/" <> config[:client_id], subject: id}}

      {:ok, %{status: status}} ->
        {:error, {:provider, status}}

      {:error, reason} ->
        {:error, {:provider, reason}}
    end
  end

  defp base_url(config), do: Keyword.get(config, :base_url, @base_url)
end
