defmodule RestaurantHost.Web.AuthController do
  @moduledoc false
  use Phoenix.Controller, formats: [:html]

  alias BizKit.Identity
  alias BizKit.Identity.Sessions

  def enabled?, do: is_binary(Application.get_env(:restaurant_host, :identity_provider))

  def principal("wsr_" <> _ = reference) do
    with {:ok, session} <- Identity.session_from_reference(reference),
         do: {:ok, session.principal}
  end

  def principal(_), do: {:error, :signed_out}

  def login(conn, params) do
    state = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    provider = Application.get_env(:restaurant_host, :identity_provider)

    with true <- is_binary(provider),
         {:ok, url} <- Identity.authorize_url(provider, state, callback_url()) do
      expires_at = System.system_time(:second) + 600
      return_path = if params["return"] == "kitchen", do: "/board", else: "/"

      conn
      |> put_session(:restaurant_login, {provider, state, expires_at, return_path})
      |> redirect(external: url)
    else
      _ -> conn |> put_status(:not_found) |> text("Sign-in is unavailable.")
    end
  end

  def callback(conn, params) do
    pending = get_session(conn, :restaurant_login)
    conn = delete_session(conn, :restaurant_login)

    with %{"state" => state, "code" => code} when is_binary(state) and is_binary(code) <- params,
         {provider, expected, expires_at, return_path} <- pending,
         true <- provider == Application.get_env(:restaurant_host, :identity_provider),
         true <- System.system_time(:second) < expires_at,
         true <- Plug.Crypto.secure_compare(expected, state),
         {:ok, token} <- Identity.login(provider, code, callback_url()) do
      revoke(conn)

      conn
      |> configure_session(renew: true)
      |> put_session(:restaurant_identity, Sessions.reference(token))
      |> redirect(to: return_path)
    else
      _ -> conn |> put_status(:forbidden) |> text("Sign-in failed.")
    end
  end

  def logout(conn, _params) do
    revoke(conn)

    conn
    |> delete_session(:restaurant_identity)
    |> delete_session(:restaurant_login)
    |> configure_session(renew: true)
    |> redirect(to: "/")
  end

  defp revoke(conn) do
    case get_session(conn, :restaurant_identity) do
      "wsr_" <> _ = reference -> Sessions.revoke_reference(reference)
      _ -> :ok
    end
  end

  defp callback_url, do: RestaurantHost.Web.Endpoint.url() <> "/auth/callback"
end
