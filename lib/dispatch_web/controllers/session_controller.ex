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
  def login(conn, _params), do: render(conn, :login, message: nil)

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
        conn |> put_status(:unauthorized) |> render(:login, message: "Sign-in failed.")
    end
  end

  def create(conn, _params) do
    conn |> put_status(:bad_request) |> render(:login, message: "A token is required.")
  end

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
    render(conn, :select_role, assignments: PrincipalResolution.selectable(subject), message: nil)
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
        conn
        |> put_status(:forbidden)
        |> render(:select_role,
          assignments: PrincipalResolution.selectable(subject),
          message: "That role is not available."
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
    |> put_status(:found)
    |> render(:redirect, to: path)
  end
end
