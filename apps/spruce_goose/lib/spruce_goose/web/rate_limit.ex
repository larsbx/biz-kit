defmodule SpruceGoose.Web.RateLimit do
  @moduledoc """
  Per-client request limits (docs/architecture/2026-10-19-rate-limits.md).
  Plugged into the endpoint ahead of `Plug.Parsers`, so a throttled request
  is refused before its body is read, and every request counts, routed or
  not. Its path decides the bucket (`bucket/1`):

    * `:sign_in`: `/auth`, `/oauth`, `/.well-known`;
    * `:capability`: `/api/v1/enrolments`, `/api/v1/grants`,
      `/api/v1/principals`, asked without a session (a code, grant or
      principal ID, and a governance signature where one is needed);
    * `:api`: everything else.

  Each bucket allows `limit` requests per client in a fixed window of
  `period_ms`, configured as

      config :spruce_goose, SpruceGoose.Web.RateLimit,
        limits: %{sign_in: {30, 60_000}, capability: {60, 60_000}, api: {600, 60_000}},
        trusted_proxies: ["10.0.0.0/8"]

  and read on every request. `overrides` replaces the buckets it names and
  leaves the rest, for an environment that is not the limiter's test (the
  end-to-end stack's `SPRUCE_GOOSE_SIGN_IN_LIMIT`). Beyond it, the request gets `429` with
  `retry-after` and goes no further.

  The client is the peer address, or, when the peer is a trusted proxy, the
  rightmost `x-forwarded-for` address that is not one: the nearest hop no
  trusted proxy vouches for. Counts are one for the cluster
  (`RateLimit.Counts`), like held commands and sessions.
  """

  @behaviour Plug

  import Bitwise
  import Plug.Conn

  alias SpruceGoose.Web.RateLimit.Counts

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    bucket = bucket(conn.path_info)
    {limit, period} = Map.fetch!(Map.merge(config(:limits, %{}), config(:overrides, %{})), bucket)
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

  @doc "The bucket a request path counts in."
  @spec bucket([String.t()]) :: :sign_in | :capability | :api
  def bucket([first | _]) when first in ~w(auth oauth .well-known), do: :sign_in

  def bucket(["api", "v1", resource | _]) when resource in ~w(enrolments grants principals),
    do: :capability

  def bucket(_path), do: :api

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
    {address, bits} =
      case String.split(text, "/") do
        [address] -> {address, nil}
        [address, bits] -> {address, Integer.parse(bits)}
        _ -> {nil, nil}
      end

    ip = (address && parse(address)) || raise ArgumentError, "not a CIDR: #{inspect(text)}"
    size = tuple_size(ip) * width(ip)

    case bits do
      nil -> {ip, size}
      {n, ""} when n >= 0 and n <= size -> {ip, n}
      _ -> raise ArgumentError, "not a CIDR: #{inspect(text)}"
    end
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

  @doc "The configured trusted proxies, parsed; raises on a malformed one."
  @spec trusted() :: [{tuple(), non_neg_integer()}]
  def trusted, do: Enum.map(config(:trusted_proxies, []), &cidr/1)

  defp config(key, default),
    do: :spruce_goose |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
end
