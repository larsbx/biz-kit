defmodule DispatchWeb.Plugs.LocationBatchParser do
  @moduledoc """
  Parses location batches before the endpoint's general parser, enforcing
  Section 24.2's cap on bytes read, before JSON decoding or signature work.
  Content-Length and the size of re-encoded JSON are not wire-byte counts.
  """
  @behaviour Plug

  @max_bytes 262_144
  @paths ["/v1/me/location-samples:batch", "/v1/driver/location-samples:batch"]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{method: "POST", request_path: path} = conn, _opts)
      when path in @paths do
    Plug.Parsers.call(
      conn,
      Plug.Parsers.init(
        parsers: [:json],
        pass: ["*/*"],
        json_decoder: Jason,
        length: @max_bytes,
        body_reader: {__MODULE__, :read_body, []}
      )
    )
  rescue
    Plug.Parsers.RequestTooLargeError ->
      DispatchWeb.Problem.send(
        conn,
        413,
        "BATCH_TOO_LARGE",
        "A batch carries at most 100 samples and 256 KiB."
      )
  end

  def call(conn, _opts), do: conn

  @doc false
  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} when byte_size(body) <= @max_bytes -> {:ok, body, conn}
      {:ok, _oversized, conn} -> {:more, "", conn}
      other -> other
    end
  end
end
