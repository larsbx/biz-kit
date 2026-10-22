defmodule DispatchWeb.Streams.Transport do
  @moduledoc """
  The socket side of every server-sent-event stream (Section 24.5): headers,
  chunks, the heartbeat timer, and noticing when the client goes away.

  What may be sent, and for how long, is the stream module's: it implements
  `tick/2` and, when it holds anything beyond its subscription, `release/1`.
  This module calls `tick/2` when

    * the heartbeat interval passes with nothing else happening (`:heartbeat`),
    * the outbox publishes on the subscribed topic (`:refresh`),
    * a `:pg` group the stream monitors gains or loses a member (`:demand`).

  Section 24.5 requires disconnect to "release database/listener resources
  promptly". The loop exits on the first failed chunk write, which is how a
  closed socket announces itself, and the subscription and whatever the stream
  holds are released on the way out rather than left for the process to carry:
  Bandit serves the next keep-alive request from the same process.
  """

  import Plug.Conn

  alias DispatchWeb.Datastar

  @type reason :: :heartbeat | :refresh | :demand

  @typedoc "Opens a stream: its session and initial snapshot, or nothing to stream."
  @type opener :: (-> {:ok, struct(), iodata()} | {:error, :not_found})

  @callback tick(session, reason()) :: {:emit, iodata(), session} | {:close, :unauthorized}
            when session: struct()
  @callback release(struct()) :: :ok
  @optional_callbacks release: 1

  @doc """
  Subscribes to `topic`, opens the stream with `open`, and serves it until the
  client leaves or `stream` closes it. Returns `{:error, :not_found}` without
  sending anything when `open` refuses, so each caller answers that its own way.

  Subscription precedes `open`. An overlapping mutation may therefore cause one
  redundant refresh, but can never fall into the gap between the snapshot query
  and listener registration.
  """
  @spec serve(Plug.Conn.t(), module(), String.t(), opener()) ::
          Plug.Conn.t() | {:error, :not_found}
  def serve(conn, stream, topic, open) do
    :ok = Phoenix.PubSub.subscribe(Dispatch.PubSub, topic)

    try do
      with {:ok, session, snapshot} <- open.() do
        try do
          opened = open_stream(conn)

          # A client can be gone before the snapshot lands: it opened the
          # stream and navigated away.
          case write(opened, snapshot) do
            :closed -> opened
            written -> run(written, stream, session)
          end
        after
          if function_exported?(stream, :release, 1), do: stream.release(session)
        end
      end
    after
      Phoenix.PubSub.unsubscribe(Dispatch.PubSub, topic)
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

  defp run(conn, stream, session) do
    receive do
      {:outbox, _payload} ->
        advance(conn, stream, session, :refresh)

      {ref, change, _group, _pids} when is_reference(ref) and change in [:join, :leave] ->
        advance(conn, stream, session, :demand)
    after
      Datastar.heartbeat_interval_ms() -> advance(conn, stream, session, :heartbeat)
    end
  end

  defp advance(conn, stream, session, reason) do
    case stream.tick(session, reason) do
      {:emit, chunk, session} ->
        # A closed socket ends the loop and returns the connection as it was.
        # Returning anything else would leak a non-conn out of a plug, which
        # Dialyzer catches and a browser would meet as a crash.
        case write(conn, chunk) do
          :closed -> conn
          written -> run(written, stream, session)
        end

      # The stream ends with the connection, not with an error frame: a client
      # told "unauthorized" in-band would reconnect, and the reconnect is
      # authorized afresh anyway.
      {:close, :unauthorized} ->
        conn
    end
  end

  # A failed write is how a closed socket reports itself, as `:closed`, or as
  # whatever the peer's reset was (`:econnreset`, `:epipe`). Treating it as the
  # exit condition is what releases the subscription and any watch promptly.
  # An empty chunk writes nothing.
  defp write(conn, chunk) do
    case chunk(conn, chunk) do
      {:ok, conn} -> conn
      {:error, _gone} -> :closed
    end
  end
end
