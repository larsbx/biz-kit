defmodule SpruceGoose.Web.AuthController do
  @moduledoc """
  Human sign-in (docs/architecture/2026-10-18-identity.md). Transport only:
  `BizKit.Identity` authenticates through the configured provider, resolves
  the principal and issues the session; the ledger's grants decide what the
  principal may do.

      GET  /auth/:provider/login     → the provider's sign-in page
      GET  /auth/:provider/callback  → session cookie, then `:after_login_path`
      POST /auth/logout              → session revoked
      GET  /auth/me                  → the signed-in principal

  The session cookie is HttpOnly, SameSite=Lax and, outside development and
  tests, Secure. It authenticates reads; it never signs a command.
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
    case principal(conn) do
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

  def callback(conn, %{"provider" => provider}) do
    conn = conn |> fetch_cookies() |> fetch_query_params()

    %{"code" => code, "state" => state} =
      Map.merge(%{"code" => nil, "state" => nil}, conn.query_params)

    expected = conn.cookies[@state_cookie]

    with true <- Enum.all?([code, state, expected], &is_binary/1) or :missing_code_or_state,
         true <- Plug.Crypto.secure_compare(expected, state) or :state_mismatch,
         {:ok, session} <- Identity.login(provider, code, callback_url(provider)) do
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

    conn
    |> delete_resp_cookie(@session_cookie, cookie_opts([]))
    |> send_resp(204, "")
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
