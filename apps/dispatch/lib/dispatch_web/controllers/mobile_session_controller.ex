defmodule DispatchWeb.MobileSessionController do
  @moduledoc "Native handoff into BizKit.Identity; no provider credential reaches Android."
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  operation(:start,
    summary: "Begin native sign-in",
    security: [],
    parameters: [],
    request_body: {"Request", "application/json", DispatchWeb.Schemas.MobileAuthorizeRequest},
    responses: [
      ok: {"Response", "application/json", DispatchWeb.Schemas.MobileAuthorizeResponse},
      unauthorized: {"Unauthenticated", "application/problem+json", DispatchWeb.Schemas.Problem},
      forbidden: {"Rejected", "application/problem+json", DispatchWeb.Schemas.Problem}
    ]
  )

  operation(:exchange,
    summary: "Exchange single-use PKCE handoff",
    security: [],
    parameters: [],
    request_body: {"Request", "application/json", DispatchWeb.Schemas.MobileTokenRequest},
    responses: [
      ok: {"Response", "application/json", DispatchWeb.Schemas.MobileTokenResponse},
      unauthorized: {"Unauthenticated", "application/problem+json", DispatchWeb.Schemas.Problem},
      forbidden: {"Rejected", "application/problem+json", DispatchWeb.Schemas.Problem}
    ]
  )

  operation(:login,
    summary: "Open the held native sign-in in a browser",
    security: [],
    parameters: [id: [in: :query, type: :string, required: true]],
    responses: [found: "Provider redirect", unauthorized: "Invalid flow"]
  )

  operation(:callback,
    summary: "Provider callback for a held native flow",
    security: [],
    parameters: [
      state: [in: :query, type: :string, required: true],
      code: [in: :query, type: :string, required: true]
    ],
    responses: [found: "Single-use native handoff redirect", unauthorized: "Invalid flow"]
  )

  operation(:logout,
    summary: "Revoke the current native session",
    security: [%{"nativeSession" => []}],
    responses: [no_content: "Session revoked", unauthorized: "Unauthenticated"]
  )

  import Plug.Conn
  alias BizKit.Identity
  alias BizKit.Identity.Native
  alias DispatchWeb.Problem

  @spec start(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def start(conn, params) do
    config = Application.get_env(:dispatch, :native_identity, [])

    with provider when is_binary(provider) <- config[:provider],
         base when is_binary(base) <- config[:public_url],
         redirect when is_binary(redirect) <- config[:redirect_uri],
         {:ok, flow} <-
           Native.begin(
             provider,
             params["code_challenge"],
             params["state"],
             base <> "/v1/mobile/callback",
             redirect
           ) do
      # The browser visits this endpoint to acquire its own HttpOnly state cookie.
      json(conn, %{
        authorization_url:
          base <>
            "/v1/mobile/login?" <>
            URI.encode_query(%{id: flow.id})
      })
    else
      _ -> Problem.send(conn, 400, "SIGN_IN_UNAVAILABLE", "Sign-in is not available.")
    end
  end

  @spec login(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def login(conn, %{"id" => id}) do
    # Retrieve the provider URL from the server, never redirect to a caller URL.
    case Native.authorization_url(id) do
      {:ok, url} ->
        conn
        |> put_resp_cookie("dispatch_native_state", id, cookie_options(600))
        |> redirect(external: url)

      _ ->
        denied(conn)
    end
  end

  def login(conn, _), do: denied(conn)

  @spec callback(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def callback(conn, %{"state" => state, "code" => code})
      when is_binary(state) and is_binary(code) do
    expected = fetch_cookies(conn).cookies["dispatch_native_state"]

    with true <- is_binary(expected) and Plug.Crypto.secure_compare(expected, state),
         {:ok, flow} <- Native.complete(state, code) do
      conn
      |> delete_resp_cookie("dispatch_native_state", cookie_options(0))
      |> redirect(
        external: flow.redirect <> "?" <> URI.encode_query(%{code: flow.code, state: flow.state})
      )
    else
      _ -> denied(conn)
    end
  end

  def callback(conn, _), do: denied(conn)

  @spec exchange(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def exchange(conn, params) do
    with {:ok, token} <- Native.exchange(params["code"], params["code_verifier"]),
         {:ok, session} <- Identity.session(token),
         {:ok, subject} <- Dispatch.Identity.Native.subject(session) do
      json(conn, %{
        access_token: token,
        token_type: "BizKit",
        subject: subject,
        principal: session.principal,
        expires_at: session.expires_at
      })
    else
      _ -> denied(conn)
    end
  end

  @spec logout(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def logout(conn, _) do
    case conn.assigns[:bizkit_session_id] do
      id when is_binary(id) ->
        Identity.logout(id)
        send_resp(conn, 204, "")

      _ ->
        denied(conn)
    end
  end

  defp denied(conn), do: Problem.send(conn, 401, "UNAUTHENTICATED", "Sign-in failed.")

  defp cookie_options(age),
    do: [
      http_only: true,
      same_site: "Lax",
      path: "/v1/mobile",
      max_age: age,
      secure: Application.get_env(:dispatch, :native_secure_cookies, true)
    ]
end
