defmodule SpruceGoose.Web.FeedController do
  @moduledoc """
  The common ledger's change feed over server-sent events
  (docs/architecture/2026-10-18-change-feed.md#transport).

  Transport only. `CoopSubstrate.Feed` decides what a reader sees and, through
  `CoopSubstrate.Feed.Access`, whether it may read: an active operator or
  suggester grant on the ledger for exactly this project. Nothing here
  consults SpruceGoose's own actors or grants.

  Agents authenticate with a signed request: `Authorization: CoopFeed
  grant="…", key="…", ts="…", nonce="…", sig="…"`, signing the method, path,
  scope and cursor of this very request (`Access.signing_bytes/1`). Human
  readers will sign in through WorkOS, mapped to a ledger principal whose grants
  are checked the same way; that path is not built yet.

  An open stream ends when the reader's grant is revoked, at the first event
  after which it is no longer active.
  """

  use Phoenix.Controller, formats: [:json]

  import Plug.Conn

  require Logger

  alias CoopSubstrate.Feed
  alias CoopSubstrate.Feed.SSE

  @doc "The stream: one frame up to the head, then a frame per change."
  def stream(conn, params) do
    conn = fetch_query_params(conn)
    scope = scope(params)

    with {:ok, cursor} <- SSE.cursor(cursor_param(conn)),
         {:ok, reader} <- signed_reader(conn, scope, cursor),
         {:ok, session, frame} <- Feed.open(scope, cursor, reader) do
      try do
        conn |> start_stream() |> send_then_run(SSE.frame(frame), session)
      after
        Feed.close(session)
      end
    else
      {:error, reason} -> refuse(conn, reason)
    end
  end

  # -- authentication ----------------------------------------------------------------

  defp signed_reader(conn, scope, cursor) do
    with [header] <- get_req_header(conn, "authorization"),
         {:ok, fields} <- parse_authorization(header),
         {ts, ""} <- Integer.parse(fields["ts"]),
         {:ok, signature} <- Base.url_decode64(fields["sig"], padding: false) do
      Feed.authorize(
        %{
          method: conn.method,
          path: conn.request_path,
          scope: scope,
          cursor: cursor,
          timestamp_ms: ts,
          nonce: fields["nonce"],
          authorization_event_id: fields["grant"],
          key_id: fields["key"]
        },
        signature
      )
    else
      _ -> {:error, :malformed_authorization}
    end
  end

  @fields ~w(grant key ts nonce sig)

  defp parse_authorization("CoopFeed " <> params) do
    fields = Map.new(Regex.scan(~r/(\w+)="([^"]*)"/, params), fn [_, k, v] -> {k, v} end)
    if Enum.all?(@fields, &Map.has_key?(fields, &1)), do: {:ok, fields}, else: :error
  end

  defp parse_authorization(_header), do: :error

  defp cursor_param(conn),
    do: List.first(get_req_header(conn, "last-event-id")) || conn.query_params["cursor"]

  defp scope(%{"chapter_id" => c, "tenant_id" => t, "project_id" => p}), do: {c, t, p}

  # Why a request was refused stays in the log, not the response.
  defp refuse(conn, :invalid_cursor), do: error(conn, 400, "invalid_cursor")
  defp refuse(conn, :cursor_ahead), do: error(conn, 409, "cursor_ahead")

  defp refuse(conn, reason) do
    Logger.info("feed read refused: #{inspect(reason)}")

    conn
    |> put_resp_header("www-authenticate", "CoopFeed")
    |> error(401, "unauthorized")
  end

  defp error(conn, status, code), do: conn |> put_status(status) |> json(%{error: code})

  # -- streaming -------------------------------------------------------------------------

  defp start_stream(conn) do
    conn
    |> put_resp_content_type("text/event-stream", nil)
    |> put_resp_header("cache-control", "no-store")
    # Without this an intermediary may buffer the stream into one late batch.
    |> put_resp_header("x-accel-buffering", "no")
    |> send_chunked(200)
  end

  defp run(conn, session) do
    receive do
      {:coop_ledger, envelopes} -> step(conn, Feed.advance(session, envelopes), nil)
    after
      heartbeat_ms() -> step(conn, Feed.tick(session), SSE.heartbeat())
    end
  end

  # Revocation ends the response; a reconnect is then refused.
  defp step(conn, {:revoked, _session}, _idle), do: conn
  defp step(conn, {nil, session}, nil), do: run(conn, session)
  defp step(conn, {nil, session}, idle), do: send_then_run(conn, idle, session)
  defp step(conn, {frame, session}, _idle), do: send_then_run(conn, SSE.frame(frame), session)

  # A failed write is how a closed socket reports itself; the stream ends there.
  defp send_then_run(conn, chunk, session) do
    case chunk(conn, chunk) do
      {:ok, conn} -> run(conn, session)
      {:error, :closed} -> conn
    end
  end

  defp heartbeat_ms, do: Application.get_env(:spruce_goose, :feed_heartbeat_ms, 15_000)
end
