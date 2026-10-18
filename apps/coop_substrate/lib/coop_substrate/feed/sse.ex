defmodule CoopSubstrate.Feed.SSE do
  @moduledoc """
  Server-sent-events framing for `CoopSubstrate.Feed`. Transport-neutral: the
  endpoint that serves it owns the socket and the authorisation.

  Each frame is one `changes` event whose `id` is its cursor, so a browser's
  `EventSource` resumes by itself: it reconnects with `Last-Event-ID`, which
  `cursor/1` turns back into the cursor `Feed.open/2` takes.
  """

  @spec frame(CoopSubstrate.Feed.frame()) :: iodata()
  def frame(%{seq: seq} = frame),
    do: [
      "id: ",
      Integer.to_string(seq),
      "\nevent: changes\ndata: ",
      Jason.encode_to_iodata!(frame),
      "\n\n"
    ]

  @doc "A comment line: keeps intermediaries from timing the stream out."
  @spec heartbeat() :: iodata()
  def heartbeat, do: ": heartbeat\n\n"

  @doc "The cursor a `Last-Event-ID` header names; no header starts from 0."
  @spec cursor(String.t() | nil) :: {:ok, non_neg_integer()} | {:error, :invalid_cursor}
  def cursor(nil), do: {:ok, 0}

  def cursor(last_event_id) do
    case Integer.parse(last_event_id) do
      {seq, ""} when seq >= 0 -> {:ok, seq}
      _ -> {:error, :invalid_cursor}
    end
  end
end
