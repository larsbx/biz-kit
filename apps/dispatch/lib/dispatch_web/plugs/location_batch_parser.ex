defmodule DispatchWeb.Plugs.LocationBatchParser do
  @moduledoc """
  Parses location batches before the endpoint's general parser, enforcing
  Section 24.2's cap on bytes read, before JSON decoding or signature work.
  Content-Length and the size of re-encoded JSON are not wire-byte counts.
  """
  @behaviour Plug

  @max_bytes 262_144

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{method: "POST", path_info: path_info} = conn, _opts) do
    # Phoenix decodes segments for route matching; enforce the cap on the same
    # paths, including escaped colons and trailing slashes.
    case Enum.map(path_info, &URI.decode/1) do
      ["v1", role, "location-samples:batch"] when role in ["me", "driver"] ->
        parse_batch(conn)

      _other ->
        conn
    end
  end

  def call(conn, _opts), do: conn

  defp parse_batch(conn) do
    Plug.Parsers.call(
      conn,
      Plug.Parsers.init(
        parsers: [:json],
        pass: [],
        json_decoder: Jason,
        length: @max_bytes,
        body_reader: {__MODULE__, :read_body, []}
      )
    )
  rescue
    Plug.Parsers.UnsupportedMediaTypeError ->
      DispatchWeb.Problem.send(
        conn,
        415,
        "UNSUPPORTED_MEDIA_TYPE",
        "Location batches require JSON."
      )

    Plug.Parsers.RequestTooLargeError ->
      DispatchWeb.Problem.send(
        conn,
        413,
        "BATCH_TOO_LARGE",
        "A batch carries at most 100 samples and 256 KiB."
      )
  end

  @doc false
  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} when byte_size(body) <= @max_bytes -> {:ok, body, conn}
      {:ok, _oversized, conn} -> {:more, "", conn}
      other -> other
    end
  end
end
