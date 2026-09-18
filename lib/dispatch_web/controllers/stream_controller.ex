defmodule DispatchWeb.StreamController do
  @moduledoc """
  The Datastar SSE endpoints of Section 24.5.

  Transport only, as Section 21.1 requires. What may be sent, and for how long,
  is `DispatchWeb.Streams.Participant`; this owns the socket: headers, chunks,
  the heartbeat timer, and noticing when the client goes away.

  Section 24.5 requires disconnect to "release database/listener resources
  promptly". The loop below exits on the first failed chunk write, which is how
  a closed socket announces itself, and the subscription is torn down on the way
  out rather than left for the process to carry.
  """

  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  alias DispatchWeb.Datastar
  alias DispatchWeb.Streams.Participant

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

    case Participant.open(conn.assigns.actor, participant_id, last_event_id: last_event_id) do
      {:ok, session, snapshot} ->
        opened = open_stream(conn)

        # A client can be gone before the snapshot lands — it opened the stream
        # and navigated away. Piping a failed write straight into the loop would
        # subscribe to a topic on behalf of a socket that no longer exists, then
        # crash on the first tick.
        case write(opened, snapshot) do
          :closed -> opened
          written -> loop(written, session)
        end

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> put_resp_content_type("text/html") |> send_resp(404, "")
    end
  end

  defp open_stream(conn) do
    conn
    |> put_resp_content_type("text/event-stream")
    |> put_resp_header("cache-control", "no-store")
    # Without this an intermediary may buffer the stream into uselessness: the
    # events arrive, eventually, in one batch, which is not a live stream.
    |> put_resp_header("x-accel-buffering", "no")
    |> send_chunked(200)
  end

  # Subscribing after the snapshot would drop anything that happened while it
  # rendered; subscribing before means a redundant patch at worst.
  defp loop(conn, session) do
    :ok = Phoenix.PubSub.subscribe(Dispatch.PubSub, topic(session))

    try do
      run(conn, session)
    after
      Phoenix.PubSub.unsubscribe(Dispatch.PubSub, topic(session))
    end
  end

  defp run(conn, session) do
    receive do
      {:outbox, _payload} -> advance(conn, session, :refresh)
    after
      Datastar.heartbeat_interval_ms() -> advance(conn, session, :heartbeat)
    end
  end

  defp advance(conn, session, reason) do
    case Participant.tick(session, reason) do
      {:emit, chunk, session} ->
        # A closed socket ends the loop and returns the connection as it was.
        # Returning anything else would leak a non-conn out of a plug, which
        # Dialyzer catches and a browser would meet as a crash.
        case write(conn, chunk) do
          :closed -> conn
          written -> run(written, session)
        end

      # The stream ends with the connection, not with an error frame: a client
      # told "unauthorized" in-band would reconnect, and the reconnect is
      # authorized afresh anyway.
      {:close, :unauthorized} ->
        conn
    end
  end

  # A failed write is how a closed socket reports itself. Treating it as the
  # exit condition is what releases the subscription promptly rather than on the
  # next heartbeat.
  defp write(conn, chunk) do
    case chunk(conn, chunk) do
      {:ok, conn} -> conn
      {:error, :closed} -> :closed
    end
  end

  defp topic(session), do: "participant:#{session.participant_id}"
end
