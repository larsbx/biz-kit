defmodule DispatchWeb.Plugs.RequireSubject do
  @moduledoc """
  Requires an authenticated subject, and nothing more.

  `DispatchWeb.Plugs.PortalSession` establishes *who* is calling and *which
  assignment they act under*. Role selection needs only the first half: a user
  holding several assignments has no selection yet, and demanding one before
  they can choose is a loop with the switcher on the far side of it.

  So this plug stops at the subject. It grants nothing — the subject alone
  carries no capability, and every page behind `PortalSession` still resolves a
  full actor before showing anything.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case get_session(conn, DispatchWeb.Plugs.PortalSession.subject_key()) do
      subject when is_binary(subject) ->
        assign(conn, :oidc_subject, subject)

      _signed_out ->
        conn
        |> put_resp_header("location", "/login")
        |> put_resp_content_type("text/html")
        |> send_resp(302, "<!DOCTYPE html><html lang=\"en\"><body><p>Sign in</p></body></html>")
        |> halt()
    end
  end
end
