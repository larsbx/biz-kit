defmodule DispatchWeb.SessionController do
  @moduledoc """
  Sign-in and role selection for the portal (Sections 23.1, 24.6, 4.3).

  Section 23.1 makes this service a resource server: it validates tokens, it
  does not run the Authorization Code flow. The portal therefore exchanges a
  token the client already obtained for an encrypted server session, and the
  session holds the *subject* — never the token, which Section 32 forbids
  logging or storing and which would be a bearer credential sitting in a cookie.

  Role selection is the browser half of Section 24.6. A chosen assignment is
  written to the session and revalidated on every subsequent request by
  `DispatchWeb.Plugs.PortalSession`; choosing one that the principal does not
  hold selects nothing, because the choice is a filter over what they hold.
  """

  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  alias Dispatch.Identity.PrincipalResolution
  alias Dispatch.Identity.Tokens.Verifier
  alias DispatchWeb.Plugs.PortalSession

  @doc "The sign-in page."
  @spec login(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def login(conn, _params), do: page(conn, 200, login_form())

  @doc """
  Exchanges a verified token for a session.

  The session is renewed on sign-in, so a session fixated before authentication
  cannot survive it.
  """
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"token" => token}) when is_binary(token) do
    case Verifier.verify(token) do
      {:ok, %{subject: subject}} ->
        conn
        |> configure_session(renew: true)
        |> put_session(PortalSession.subject_key(), subject)
        |> redirect_to("/select-role")

      {:error, _reason} ->
        # One message for every reason, as Section 24.7 requires of reason
        # codes: which part of the token failed is more use to an attacker.
        page(conn, 401, login_form("Sign-in failed."))
    end
  end

  def create(conn, _params), do: page(conn, 400, login_form("A token is required."))

  @doc "Ends the session."
  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, _params), do: conn |> clear_session() |> redirect_to("/login")

  @doc """
  The role/scope switcher of Section 4.3.

  Reached when a principal holds several assignments and has chosen none:
  Section 23.3 forbids unioning capabilities, so the choice is theirs to make.
  """
  @spec select_role(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def select_role(conn, _params) do
    subject = get_session(conn, PortalSession.subject_key())
    page(conn, 200, role_form(PrincipalResolution.selectable(subject)))
  end

  @doc "Records the selection. Only assignments the principal holds are offered or accepted."
  @spec choose_role(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def choose_role(conn, %{"role_assignment_id" => assignment_id}) do
    subject = get_session(conn, PortalSession.subject_key())

    case PrincipalResolution.actor(subject, assignment_id) do
      {:ok, actor} ->
        conn
        |> put_session(PortalSession.assignment_key(), actor.role_assignment.id)
        |> redirect_to(landing_for(actor))

      {:error, _not_held} ->
        page(
          conn,
          403,
          role_form(PrincipalResolution.selectable(subject), "That role is not available.")
        )
    end
  end

  def choose_role(conn, _params), do: redirect_to(conn, "/select-role")

  # Section 4.3's primary route per profile. A profile with no page of its own
  # yet lands on role selection rather than a route that does not exist.
  defp landing_for(actor) do
    case actor.role_assignment.scope_type do
      :STOP -> "/partner/stops/#{actor.role_assignment.scope_id}"
      _otherwise -> "/select-role"
    end
  end

  defp redirect_to(conn, path) do
    conn
    |> put_resp_header("location", path)
    |> page(302, ~s(<p><a href="#{Plug.HTML.html_escape(path)}">Continue</a></p>))
  end

  defp page(conn, status, body) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(status, """
    <!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>Dispatch</title></head>\
    <body>#{body}</body></html>\
    """)
  end

  # Section 26.4 requires CSRF protection on every action form. The token is
  # rendered here rather than left to the pipeline because `protect_from_forgery`
  # only *checks* it — a form without one fails for everybody, including the
  # legitimate user, which is how this requirement usually surfaces.
  defp csrf_field do
    ~s(<input type="hidden" name="_csrf_token" value="#{Plug.CSRFProtection.get_csrf_token()}" />)
  end

  defp alert(nil), do: ""
  defp alert(message), do: ~s(<p role="alert">#{Plug.HTML.html_escape(message)}</p>)

  defp login_form(message \\ nil) do
    """
    #{alert(message)}
    <form method="post" action="/session">
      #{csrf_field()}
      <label for="token">Access token</label>
      <input id="token" name="token" type="password" autocomplete="off" />
      <button type="submit">Sign in</button>
    </form>
    """
  end

  defp role_form(assignments, message \\ nil) do
    options =
      Enum.map_join(assignments, "", fn assignment ->
        ~s(<option value="#{Plug.HTML.html_escape(assignment.id)}">) <>
          Plug.HTML.html_escape(assignment.label) <> "</option>"
      end)

    """
    #{alert(message)}
    <form method="post" action="/select-role">
      #{csrf_field()}
      <label for="role_assignment_id">Acting as</label>
      <select id="role_assignment_id" name="role_assignment_id">#{options}</select>
      <button type="submit">Continue</button>
    </form>
    """
  end
end
