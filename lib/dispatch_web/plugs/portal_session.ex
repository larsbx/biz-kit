defmodule DispatchWeb.Plugs.PortalSession do
  @moduledoc """
  Establishes the actor for a browser request (Section 24.6).

  > Browser role selection is stored in the encrypted server session and
  > revalidated on every request and SSE event. The header or session value
  > selects authority context but never grants it.

  The machine API takes its selection from `X-Role-Assignment-ID`; the portal
  takes it from the encrypted session. That is the only difference. Both are a
  *selection* among assignments the principal already holds, and both resolve
  through `Dispatch.Identity.PrincipalResolution`, which re-reads every one from
  the database. A session cookie carrying an assignment the user no longer holds
  therefore selects nothing — the cookie is not a capability, and nothing here
  treats it as one.

  "Revalidated on every request" is why this is a plug on the pipeline rather
  than something done at sign-in and remembered. A role revoked mid-session ends
  at the next page load, not at the next login.
  """

  @behaviour Plug

  import Plug.Conn

  alias Dispatch.Identity.PrincipalResolution

  @session_subject "oidc_subject"
  @session_assignment "role_assignment_id"

  @doc "The session key holding the authenticated subject."
  @spec subject_key() :: String.t()
  def subject_key, do: @session_subject

  @doc "The session key holding the selected role assignment."
  @spec assignment_key() :: String.t()
  def assignment_key, do: @session_assignment

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case get_session(conn, @session_subject) do
      subject when is_binary(subject) -> resolve(conn, subject)
      _signed_out -> redirect_to_login(conn)
    end
  end

  defp resolve(conn, subject) do
    requested = get_session(conn, @session_assignment)

    case PrincipalResolution.actor(subject, requested) do
      {:ok, actor} ->
        conn
        |> assign(:actor, actor)
        |> assign(:tenant, actor.tenant_id)
        # Written back so a session that selected nothing in particular settles
        # on what it resolved to, and so a stale selection is replaced rather
        # than re-resolved on every request.
        |> put_session(@session_assignment, actor.role_assignment.id)

      {:error, :ambiguous_role_assignment} ->
        # Section 4.3: several assignments and no choice made is a question for
        # the user, not something to decide for them — Section 23.3 forbids
        # unioning, so guessing would be a union by another name.
        conn |> redirect(to: "/select-role") |> halt()

      {:error, _no_usable_assignment} ->
        # A selection that no longer resolves is indistinguishable from not
        # being signed in, which is the safe reading: the session carries no
        # authority of its own.
        conn |> clear_session() |> redirect_to_login()
    end
  end

  defp redirect_to_login(conn), do: conn |> redirect(to: "/login") |> halt()

  # Phoenix.Controller.redirect/2 would pull the whole controller surface into a
  # plug that needs one header and one status.
  defp redirect(conn, to: path) do
    conn
    |> put_resp_header("location", path)
    |> put_resp_content_type("text/html")
    |> send_resp(
      302,
      ~s(<html><body><a href="#{Plug.HTML.html_escape(path)}">Continue</a></body></html>)
    )
  end
end
