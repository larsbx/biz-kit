defmodule SpruceGoose.Web.RateLimitTest do
  @moduledoc """
  Request limits per client (docs/architecture/2026-10-19-rate-limits.md):
  every request counts in a bucket, before its body is read; beyond its
  limit a client gets 429 and nothing else, while other clients and other
  buckets are unaffected. Requests go through the endpoint, as served.
  """
  use ExUnit.Case, async: false

  alias SpruceGoose.Web.{Endpoint, RateLimit, Router}

  setup do
    start_supervised!(Endpoint)
    config = Application.get_env(:spruce_goose, RateLimit)
    on_exit(fn -> Application.put_env(:spruce_goose, RateLimit, config) end)
    :ok
  end

  defp limits!(limits, proxies \\ []),
    do:
      Application.put_env(:spruce_goose, RateLimit,
        limits:
          Map.merge(
            %{sign_in: {100, 60_000}, capability: {100, 60_000}, api: {100, 60_000}},
            limits
          ),
        trusted_proxies: proxies
      )

  # A client address no other test uses.
  defp ip, do: {198, 51, 100, :rand.uniform(250)} |> then(&put_elem(&1, 2, :rand.uniform(250)))

  defp request(verb, path, ip, headers \\ [], body \\ nil) do
    conn = Plug.Test.conn(verb, path, body)

    %{conn | remote_ip: ip}
    |> then(&Enum.reduce(headers, &1, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end))
    |> Endpoint.call([])
  end

  defp get(path, ip, headers \\ []), do: request(:get, path, ip, headers)

  @enrolment "/api/v1/enrolments/AAAA-AAAA-AAAA"

  test "beyond its limit a client gets 429 with retry-after, and nothing else" do
    limits!(%{capability: {3, 60_000}})
    client = ip()

    assert for(_ <- 1..3, do: get(@enrolment, client).status) == [404, 404, 404]

    conn = get(@enrolment, client)
    assert conn.status == 429
    assert Jason.decode!(conn.resp_body) == %{"error" => "rate_limited"}
    assert [seconds] = Plug.Conn.get_resp_header(conn, "retry-after")
    assert String.to_integer(seconds) in 1..60

    # Another client, and another bucket for this one, are unaffected.
    assert get(@enrolment, ip()).status == 404
    assert get("/auth/me", client).status == 401
  end

  test "a new window starts afresh" do
    limits!(%{capability: {1, 100}})
    client = ip()

    assert get(@enrolment, client).status == 404
    assert get(@enrolment, client).status == 429
    Process.sleep(110)
    assert get(@enrolment, client).status == 404
  end

  test "a throttled client is refused before its body is read" do
    limits!(%{capability: {1, 60_000}})
    client = ip()
    json = [{"content-type", "application/json"}]
    path = "/api/v1/grants/x/revocation"

    # Counted, then refused by the parser (a 400 when served).
    assert_raise Plug.Parsers.ParseError, fn ->
      request(:post, path, client, json, "{not json")
    end

    for body <- ["{not json", Jason.encode!(%{"pad" => String.duplicate("x", 100_000)})] do
      assert request(:post, path, client, json, body).status == 429
    end
  end

  # With every limit at zero, any request not counted would answer otherwise.
  test "every route, and every other path, counts in a bucket" do
    limits!(%{sign_in: {0, 60_000}, capability: {0, 60_000}, api: {0, 60_000}})
    client = ip()

    paths =
      for route <- Phoenix.Router.routes(Router), uniq: true do
        {if(route.verb == :*, do: :get, else: route.verb),
         String.replace(route.path, ~r/:\w+|\*\w+/, "x")}
      end

    statuses =
      for {verb, path} <- [{:get, "/no/such/route"} | paths],
          do: {verb, path, request(verb, path, client).status}

    assert length(statuses) > 20
    assert Enum.reject(statuses, &match?({_, _, 429}, &1)) == []
  end

  test "the path decides the bucket" do
    for {path, bucket} <- [
          {"/auth/workos/login", :sign_in},
          {"/oauth/token", :sign_in},
          {"/.well-known/oauth-authorization-server", :sign_in},
          {"/api/v1/enrolments/AAAA-AAAA-AAAA", :capability},
          {"/api/v1/grants/x/revocation", :capability},
          {"/api/v1/principals/x/offboarding", :capability},
          {"/api/v1/commands/x", :api},
          {"/api/v1/chapters/c/tenants/t/projects/p/feed", :api},
          {"/app", :api},
          {"/mcp", :api},
          {"/", :api}
        ] do
      assert RateLimit.bucket(String.split(path, "/", trim: true)) == bucket, path
    end
  end

  describe "the client behind proxies" do
    @proxies ["10.0.0.0/8", "fd00::/8"]

    defp client(remote, forwarded),
      do:
        RateLimit.client(
          %{Plug.Test.conn(:get, "/") | remote_ip: remote}
          |> Plug.Conn.put_req_header("x-forwarded-for", forwarded),
          Enum.map(@proxies, &RateLimit.cidr/1)
        )

    test "is the nearest hop no trusted proxy vouches for" do
      assert client({10, 0, 0, 5}, "203.0.113.7, 10.1.2.3") == {203, 0, 113, 7}
      assert client({10, 0, 0, 5}, "198.51.100.1, 203.0.113.7") == {203, 0, 113, 7}

      assert client({0xFD00, 0, 0, 0, 0, 0, 0, 1}, "2001:db8::1") ==
               {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}
    end

    test "is the peer when the peer is not trusted, whatever it forwards" do
      assert client({203, 0, 113, 9}, "198.51.100.1") == {203, 0, 113, 9}
    end

    test "stops at the last trusted hop when the header is not an address" do
      assert client({10, 0, 0, 5}, "nonsense") == {10, 0, 0, 5}
    end

    test "counts forwarded clients apart" do
      limits!(%{capability: {1, 60_000}}, @proxies)
      proxy = {10, 9, 9, 9}
      a = [{"x-forwarded-for", "203.0.113.#{:rand.uniform(250)}"}]
      b = [{"x-forwarded-for", "2001:db8::#{:rand.uniform(9999)}"}]

      assert get(@enrolment, proxy, a).status == 404
      assert get(@enrolment, proxy, a).status == 429
      assert get(@enrolment, proxy, b).status == 404
    end
  end

  test "ended windows are swept" do
    alias SpruceGoose.Web.RateLimit.Counts
    key = {:test, make_ref()}
    past = System.system_time(:millisecond) - 1

    assert Counts.hit(key, past) == 1
    assert Counts.hit(key, past) == 2
    send(Counts, :sweep)
    _ = :sys.get_state(Counts)
    assert Counts.hit(key, past) == 1
  end

  test "cidr parses an address with or without its prefix length" do
    assert RateLimit.cidr("10.0.0.0/8") == {{10, 0, 0, 0}, 8}
    assert RateLimit.cidr("192.0.2.1") == {{192, 0, 2, 1}, 32}
    assert RateLimit.cidr("::1") == {{0, 0, 0, 0, 0, 0, 0, 1}, 128}
    assert RateLimit.cidr("::/0") == {{0, 0, 0, 0, 0, 0, 0, 0}, 0}

    for bad <- ~w(nope/8 10.0.0.0/-1 10.0.0.0/33 ::/129 10.0.0.0/8x 10.0.0.0/8/8 /8) do
      assert_raise ArgumentError, fn -> RateLimit.cidr(bad) end
    end
  end
end
