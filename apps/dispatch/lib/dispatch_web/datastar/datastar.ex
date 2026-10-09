defmodule DispatchWeb.Datastar do
  @moduledoc """
  The single owner of Datastar SSE encoding (Section 21.5).

  Section 21.5 forbids controllers from hand-encoding Datastar events, and
  Section 24.5 fixes the wire format precisely: a `datastar-patch-elements`
  event, one `data: elements ` line per line of HTML, and a terminating blank
  line. Those rules live here and are covered by golden-wire-format tests, so a
  formatting regression fails a test instead of silently breaking every open
  portal stream.

  Authorization is deliberately not this module's concern. Section 24.5 requires
  SSE content to be field-authorized before it reaches the encoder, because the
  browser never filters confidential fields.
  """

  @patch_elements_event "datastar-patch-elements"
  @heartbeat_interval_ms 20_000

  @doc "The interval between comment heartbeats required by Section 24.5."
  @spec heartbeat_interval_ms() :: pos_integer()
  def heartbeat_interval_ms, do: @heartbeat_interval_ms

  @doc """
  Encodes one `datastar-patch-elements` event.

  `html` must already be authorized for the connected viewer. `id` becomes the
  SSE event id so a client can present it as `Last-Event-ID` on reconnect.

      iex> DispatchWeb.Datastar.patch_elements(~s(<p id="a">hi</p>), id: "e1")
      "id: e1\\nevent: datastar-patch-elements\\ndata: elements <p id=\\"a\\">hi</p>\\n\\n"
  """
  @spec patch_elements(iodata(), keyword()) :: binary()
  def patch_elements(html, opts \\ []) do
    lines =
      html
      |> IO.iodata_to_binary()
      |> String.split("\n")
      |> Enum.map(&("data: elements " <> &1 <> "\n"))

    IO.iodata_to_binary([
      event_id_line(Keyword.get(opts, :id)),
      "event: ",
      @patch_elements_event,
      "\n",
      lines,
      "\n"
    ])
  end

  @doc """
  Encodes several fragments as one event.

  Section 24.5 permits patching several elements in one event provided each
  top-level element carries a globally unique stable ID; the caller supplies
  fragments that already satisfy that.
  """
  @spec patch_many([iodata()], keyword()) :: binary()
  def patch_many(fragments, opts \\ []) when is_list(fragments) do
    fragments
    |> Enum.map_join("\n", &IO.iodata_to_binary/1)
    |> patch_elements(opts)
  end

  @doc """
  A comment heartbeat.

  Comment frames keep an idle connection and its intermediaries alive without
  patching anything, so a quiet stream cannot be mistaken for a stalled one.

      iex> DispatchWeb.Datastar.heartbeat()
      ": heartbeat\\n\\n"
  """
  @spec heartbeat() :: binary()
  def heartbeat, do: ": heartbeat\n\n"

  @doc """
  The retry hint sent once when a stream opens.

  Section 26.7 requires bounded exponential backoff on the client; this sets the
  floor the browser starts from.
  """
  @spec retry(pos_integer()) :: binary()
  def retry(ms) when is_integer(ms) and ms > 0, do: "retry: #{ms}\n\n"

  defp event_id_line(nil), do: []
  defp event_id_line(id), do: ["id: ", to_string(id), "\n"]
end
