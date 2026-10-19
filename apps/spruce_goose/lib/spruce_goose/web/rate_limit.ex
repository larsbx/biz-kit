defmodule SpruceGoose.Web.RateLimit do
  @moduledoc """
  Per-client request limits (docs/architecture/2026-10-19-rate-limits.md).

      plug(SpruceGoose.Web.RateLimit, :capability)

  Each bucket allows `limit` requests per client in a fixed window of
  `period_ms`, configured as

      config :spruce_goose, SpruceGoose.Web.RateLimit,
        limits: %{sign_in: {30, 60_000}, capability: {60, 60_000}, api: {600, 60_000}},
        trusted_proxies: ["10.0.0.0/8"]

  and read on every request. Beyond it, the request gets `429` with
  `retry-after` and goes no further.

  The client is the peer address, or, when the peer is a trusted proxy, the
  rightmost `x-forwarded-for` address that is not one: the nearest hop no
  trusted proxy vouches for. Counts live in this node's memory, like held
  commands and sessions; several nodes would each count their own share.
  """

  @behaviour Plug

  import Bitwise
  import Plug.Conn

  alias SpruceGoose.Web.RateLimit.Counts

  @impl Plug
  def init(bucket) when is_atom(bucket), do: bucket

  @impl Plug
  def call(conn, bucket) do
    {limit, period} = Map.fetch!(config(:limits, %{}), bucket)
    now = System.system_time(:millisecond)
    ends = (div(now, period) + 1) * period
    key = {bucket, client(conn, trusted())}

    if Counts.hit(key, ends) <= limit do
      conn
    else
      conn
      |> put_resp_header("retry-after", Integer.to_string(div(ends - now + 999, 1000)))
      |> put_resp_content_type("application/json")
      |> send_resp(429, ~s({"error":"rate_limited"}))
      |> halt()
    end
  end

  @doc """
  The client a request counts against: the peer, or behind trusted proxies
  the rightmost forwarded address none of them vouches for.
  """
  @spec client(Plug.Conn.t(), [{tuple(), non_neg_integer()}]) :: tuple()
  def client(conn, trusted) do
    hops =
      conn
      |> get_req_header("x-forwarded-for")
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&parse(String.trim(&1)))

    [conn.remote_ip | Enum.reverse(hops)]
    |> Enum.reduce_while(conn.remote_ip, fn
      ip, _client when is_tuple(ip) ->
        if trusted?(ip, trusted), do: {:cont, ip}, else: {:halt, ip}

      _unparsable, client ->
        {:halt, client}
    end)
  end

  @doc "`\"10.0.0.0/8\"` as `{address, prefix bits}`."
  @spec cidr(String.t()) :: {tuple(), non_neg_integer()}
  def cidr(text) do
    [address | bits] = String.split(text, "/")
    ip = parse(address) || raise ArgumentError, "not an address: #{inspect(text)}"
    size = tuple_size(ip) * width(ip)
    {ip, if(bits == [], do: size, else: String.to_integer(hd(bits)))}
  end

  defp trusted?(ip, trusted), do: Enum.any?(trusted, &within?(ip, &1))

  defp within?(ip, {net, bits}) when tuple_size(ip) == tuple_size(net) do
    shift = tuple_size(ip) * width(ip) - bits
    integer(ip) >>> shift == integer(net) >>> shift
  end

  defp within?(_ip, _cidr), do: false

  defp width(ip), do: if(tuple_size(ip) == 4, do: 8, else: 16)

  defp integer(ip),
    do: ip |> Tuple.to_list() |> Enum.reduce(0, &(&2 <<< width(ip) ||| &1))

  defp parse(text) do
    case :inet.parse_strict_address(String.to_charlist(text)) do
      {:ok, ip} -> ip
      {:error, _} -> nil
    end
  end

  defp trusted, do: Enum.map(config(:trusted_proxies, []), &cidr/1)

  defp config(key, default),
    do: :spruce_goose |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
end
