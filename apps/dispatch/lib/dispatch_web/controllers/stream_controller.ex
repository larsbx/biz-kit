defmodule DispatchWeb.StreamController do
  @moduledoc """
  The Datastar SSE endpoints of Section 24.5.

  Routing only, as Section 21.1 requires. What may be sent, and for how long, is
  the stream module's; the socket is `DispatchWeb.Streams.Transport`'s.
  """

  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  alias DispatchWeb.Plugs.PortalSession
  alias DispatchWeb.Streams.{Operations, Participant, Transport}

  @doc "The carrier-scoped operations roster stream."
  @spec operations(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def operations(conn, _params) do
    actor = conn.assigns.actor
    topic = "operations:#{actor.role_assignment.organization_id}"

    conn
    |> Transport.serve(Operations, topic, fn -> Operations.open(actor) end,
      authorize: &authorized_tick/2
    )
    |> or_not_found(conn)
  end

  @doc """
  The live participant stream.

  An unauthorized viewer gets a 404 with no body — Section 33.2 requires an
  unauthorized stream to return "no protected fragment or coordinates", and
  acceptance criterion 19's reasoning applies to a stream as much as a page: a
  403 would confirm the participant exists.
  """
  @spec participant(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def participant(conn, %{"participant_id" => participant_id}) do
    last_event_id = List.first(get_req_header(conn, "last-event-id"))

    open = fn ->
      Participant.open(conn.assigns.actor, participant_id, last_event_id: last_event_id)
    end

    conn
    |> Transport.serve(Participant, "participant:#{participant_id}", open,
      authorize: &authorized_tick/2
    )
    |> or_not_found(conn)
  end

  @doc """
  Runs `tick` only while the portal session behind `conn` is still live
  (docs/architecture/2026-10-23-revocation-aware-portal.md): a browser session
  revoked at its source loses its stream at the next tick, heartbeat included.
  """
  def authorized_tick(conn, tick) do
    case PortalSession.authenticate(conn) do
      {:ok, _, _} -> tick.()
      _ -> {:close, :unauthorized}
    end
  end

  defp or_not_found(%Plug.Conn{} = served, _conn), do: served

  defp or_not_found({:error, :not_found}, conn) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(404, "")
  end
end
