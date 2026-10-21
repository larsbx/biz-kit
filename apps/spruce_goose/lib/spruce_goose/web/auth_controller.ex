defmodule SpruceGoose.Web.AuthController do
  @moduledoc """
  Human sign-in (docs/architecture/2026-10-18-identity.md). Transport only:
  `BizKit.Identity` authenticates through the configured provider, resolves
  the principal and issues the session; the ledger's grants decide what the
  principal may do.

      GET  /auth/:provider/login         → the provider's sign-in page
      GET  /auth/:provider/callback      → session cookie, then `:after_login_path`
      POST /auth/logout                  → session revoked
      GET  /auth/me                      → the signed-in principal

  Native apps (docs/architecture/2026-10-21-native-sign-in.md, RFC 8252):

      GET  /auth/:provider/native/login  → the provider's sign-in page, for an app's PKCE request
      GET  /auth/:provider/callback      → back to the app with a one-time code
      POST /auth/token                   → code + verifier → bearer session

  The session cookie is HttpOnly, SameSite=Lax and, outside development and
  tests, Secure. It authenticates reads; it never signs a command. A native
  app's session is the same session, carried as `Authorization: Bearer`;
  `/auth/me` and `/auth/logout` accept it, and dispatch's `/v1` API does.
  """

  use Phoenix.Controller, formats: [:json]

  import Plug.Conn

  require Logger

  alias BizKit.Identity

  @session_cookie "bizkit_session"
  @state_cookie "bizkit_login_state"

  @doc """
  The signed-in principal and its session ID, from the session cookie. Every
  endpoint a person reaches resolves them here.
  """
  @spec principal(Plug.Conn.t()) :: {:ok, String.t(), String.t()} | {:error, atom()}
  def principal(conn) do
    with {:ok, session, id} <- session(conn), do: {:ok, session.principal, id}
  end

  @doc "The live session itself (principal and the identity it signed in with) and its ID."
  @spec session(Plug.Conn.t()) :: {:ok, map(), String.t()} | {:error, atom()}
  def session(conn) do
    with id when is_binary(id) <-
           fetch_cookies(conn).cookies[@session_cookie] || {:error, :no_credentials},
         {:ok, session} <- Identity.session(id),
         do: {:ok, session, id}
  end

  def me(conn, _params) do
    case bearer_or_cookie_principal(conn) do
      {:ok, principal, _session} -> json(conn, %{principal: principal})
      {:error, reason} -> refuse(conn, reason)
    end
  end

  def login(conn, %{"provider" => provider}) do
    state = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

    case Identity.authorize_url(provider, state, callback_url(provider)) do
      {:ok, url} ->
        conn
        |> put_resp_cookie(@state_cookie, state, cookie_opts(max_age: 600))
        |> redirect(external: url)

      {:error, :unknown_provider} ->
        conn |> put_status(404) |> json(%{error: "unknown_provider"})
    end
  end

  @doc """
  A native app starts sign-in in the system browser (RFC 8252 §6) with its
  allowlisted redirect URI and an S256 PKCE challenge. The browser leaves with
  the same state cookie a web sign-in sets, so the shared callback can tell
  that the state is this browser's.
  """
  def native_login(conn, %{"provider" => provider}) do
    conn = fetch_query_params(conn)
    params = conn.query_params

    with {:ok, request} <-
           Identity.native_begin(
             provider,
             params["redirect_uri"],
             params["code_challenge"],
             params["code_challenge_method"],
             params["state"]
           ),
         {:ok, url} <- Identity.authorize_url(provider, request, callback_url(provider)) do
      conn
      |> put_resp_cookie(@state_cookie, request, cookie_opts(max_age: 600))
      |> redirect(external: url)
    else
      {:error, :unknown_provider} ->
        conn |> put_status(404) |> json(%{error: "unknown_provider"})

      # Nothing redirects to an unvalidated URI (RFC 6749 §4.1.2.1).
      {:error, reason} ->
        conn |> put_status(400) |> json(%{error: "invalid_request", reason: reason})
    end
  end

  @doc "RFC 6749 §4.1.3 for a native app: one-time code and PKCE verifier for a session."
  def token(conn, params) do
    with "authorization_code" <- params["grant_type"],
         [code, verifier, redirect_uri]
         when is_binary(code) and is_binary(verifier) and is_binary(redirect_uri) <-
           [params["code"], params["code_verifier"], params["redirect_uri"]],
         {:ok, session, expires_in} <- Identity.native_exchange(code, verifier, redirect_uri) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> json(%{access_token: session, token_type: "Bearer", expires_in: expires_in})
    else
      reason ->
        Logger.info("native token refused: #{inspect(reason)}")
        conn |> put_status(400) |> json(%{error: "invalid_grant"})
    end
  end

  def callback(conn, %{"provider" => provider}) do
    conn = conn |> fetch_cookies() |> fetch_query_params()

    %{"code" => code, "state" => state} =
      Map.merge(%{"code" => nil, "state" => nil}, conn.query_params)

    expected = conn.cookies[@state_cookie]

    with true <- Enum.all?([code, state, expected], &is_binary/1) or :missing_code_or_state,
         true <- Plug.Crypto.secure_compare(expected, state) or :state_mismatch do
      if Identity.native_request?(state),
        do: native_callback(conn, provider, state, code),
        else: web_callback(conn, provider, code)
    else
      reason -> refuse(conn, reason)
    end
  end

  # The browser came from an app: back to it, with a code or a denial. The
  # request's redirect URI was validated when it began.
  defp native_callback(conn, provider, request, code) do
    conn = delete_resp_cookie(conn, @state_cookie, cookie_opts([]))

    case Identity.native_complete(provider, request, code, callback_url(provider)) do
      {:ok, url} ->
        redirect(conn, external: url)

      {:denied, url, reason} ->
        Logger.info("native sign-in refused: #{inspect(reason)}")
        redirect(conn, external: url)

      {:error, reason} ->
        refuse(conn, reason)
    end
  end

  defp web_callback(conn, provider, code) do
    with {:ok, session} <- Identity.login(provider, code, callback_url(provider)) do
      conn
      |> delete_resp_cookie(@state_cookie, cookie_opts([]))
      |> put_resp_cookie(
        @session_cookie,
        session,
        cookie_opts(max_age: div(Identity.session_ttl_ms(), 1000))
      )
      |> redirect(to: Application.get_env(:spruce_goose, :after_login_path, "/"))
    else
      reason -> refuse(conn, reason)
    end
  end

  def logout(conn, _params) do
    conn = fetch_cookies(conn)
    if session = conn.cookies[@session_cookie], do: Identity.logout(session)
    if session = bearer(conn), do: Identity.logout(session)

    conn
    |> delete_resp_cookie(@session_cookie, cookie_opts([]))
    |> send_resp(204, "")
  end

  # A native app's session. Only `/auth/me` and `/auth/logout` read it here:
  # elsewhere in SpruceGoose an Authorization header means a signed request.
  defp bearer_or_cookie_principal(conn) do
    case bearer(conn) do
      nil ->
        principal(conn)

      session ->
        with {:ok, %{principal: principal}} <- Identity.session(session),
             do: {:ok, principal, session}
    end
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> session] when session != "" -> session
      _ -> nil
    end
  end

  # Why a sign-in failed stays in the log, not the response.
  defp refuse(conn, reason) do
    Logger.info("sign-in refused: #{inspect(reason)}")
    conn |> put_status(401) |> json(%{error: "unauthorized"})
  end

  defp callback_url(provider),
    do:
      Application.get_env(:spruce_goose, :public_url, "http://127.0.0.1:4000") <>
        "/auth/#{provider}/callback"

  defp cookie_opts(opts),
    do:
      [
        http_only: true,
        same_site: "Lax",
        secure: Application.get_env(:spruce_goose, :secure_cookies, true),
        path: "/"
      ] ++ opts
end
