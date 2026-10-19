defmodule SpruceGoose.Web.RateLimitTest do
  @moduledoc """
  Request limits per client (docs/architecture/2026-10-19-rate-limits.md):
  every route has a bucket; beyond its limit a client gets 429 and nothing
  else, while other clients and other buckets are unaffected.
  """
  use ExUnit.Case, async: false

  alias SpruceGoose.Web.{RateLimit, Router}

  setup do
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

  defp get(path, ip, headers \\ []) do
    conn = Plug.Test.conn(:get, path)

    %{conn | remote_ip: ip}
    |> then(&Enum.reduce(headers, &1, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end))
    |> Router.call(Router.init([]))
  end

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

  # With every limit at zero, a route without a bucket would answer otherwise.
  test "every route has a bucket" do
    limits!(%{sign_in: {0, 60_000}, capability: {0, 60_000}, api: {0, 60_000}})
    client = ip()

    statuses =
      for route <- Phoenix.Router.routes(Router), uniq: true do
        verb = if route.verb == :*, do: :get, else: route.verb
        path = String.replace(route.path, ~r/:\w+|\*\w+/, "x")
        conn = %{Plug.Test.conn(verb, path) | remote_ip: client} |> Router.call(Router.init([]))
        {route.verb, route.path, conn.status}
      end

    assert statuses != []
    assert Enum.reject(statuses, &match?({_, _, 429}, &1)) == []
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
    assert_raise ArgumentError, fn -> RateLimit.cidr("nope/8") end
  end
end
