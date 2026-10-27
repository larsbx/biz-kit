defmodule FederationService.TwoInstanceTest do
  use ExUnit.Case, async: false
  import FederationService.TestHelpers
  alias FederationService.{Network, Signature}
  @moduletag timeout: 120_000

  defp port do
    {:ok, s} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, n} = :inet.port(s)
    :gen_tcp.close(s)
    n
  end

  defp node(dir, host, port, other, other_port, certs, peers \\ nil) do
    beams = Path.wildcard(Path.expand("../../../../_build/test/lib/*/ebin", __DIR__))
    # Under isolated staging, __DIR__ may point through a symlink; code paths
    # already loaded in this VM are the authoritative build location.
    beams = Enum.uniq(beams ++ Enum.map(:code.get_path(), &to_string/1))

    args =
      Enum.flat_map(beams, fn p -> ["-pa", p] end) ++
        [
          Path.join(__DIR__, "support/node.exs"),
          dir,
          host,
          to_string(port),
          other,
          to_string(other_port),
          certs
        ]

    args = if peers == nil, do: args, else: args ++ [Jason.encode!(peers)]

    p =
      Port.open({:spawn_executable, System.find_executable("elixir")}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        args: args,
        env: [{~c"ERL_FLAGS", ~c"+S 2:2"}]
      ])

    line(p, "READY")
    p
  end

  defp line(p, prefix, buffer \\ "") do
    case String.split(buffer, "\n", parts: 2) do
      [first, rest] ->
        if String.starts_with?(first, prefix),
          do: String.replace_prefix(first, prefix, ""),
          else: line(p, prefix, rest)

      _ ->
        receive do
          {^p, {:data, chunk}} -> line(p, prefix, buffer <> chunk)
          {^p, {:exit_status, status}} -> flunk("node exited #{status}: #{buffer}")
        after
          20_000 -> flunk("node timed out: #{buffer}")
        end
    end
  end

  defp command(p, req) do
    Port.command(p, Jason.encode!(req) <> "\n")
    p |> line("RESULT ") |> Jason.decode!()
  end

  defp stop(p) do
    if Port.info(p) do
      Port.command(p, "{\"op\":\"stop\"}\n")

      receive do
        {^p, {:exit_status, 0}} -> :ok
      after
        5000 -> if Port.info(p), do: Port.close(p)
      end
    end
  end

  defp eventually(fun, attempts \\ 60) do
    if fun.(),
      do: :ok,
      else:
        (if attempts > 0 do
           Process.sleep(100)
           eventually(fun, attempts - 1)
         else
           flunk("eventual delivery did not complete")
         end)
  end

  test "signed Follow and Undo are durably admitted without business or peer authority" do
    dir = temp()
    ca = certs(dir)
    a_port = port()
    b_port = port()
    a_dir = dir <> "/alpha"
    b_dir = dir <> "/beta"
    a = node(a_dir, "alpha.example", a_port, "beta.example", b_port, dir)
    b = node(b_dir, "beta.example", b_port, "alpha.example", a_port, dir)

    on_exit(fn ->
      stop(a)
      stop(b)
      File.rm_rf!(dir)
    end)

    net = [
      test_routes: %{
        "alpha.example" => {{127, 0, 0, 1}, a_port},
        "beta.example" => {{127, 0, 0, 1}, b_port}
      },
      test_cacerts: [ca]
    ]

    alpha = "https://alpha.example/actors/shop"
    beta = "https://beta.example/actors/shop"
    url = beta <> "/inbox"
    key = Signature.private!(a_dir <> "/signing.key")

    {:ok, follow} =
      FederationCore.Subscriptions.follow(alpha, beta, alpha <> "/activities/follow-1")

    send_signed = fn message ->
      body = Jason.encode!(message)
      Network.request(:post, url, Signature.sign(url, alpha, key, body), body, net)
    end

    assert {:ok, 202, _, _} = send_signed.(follow)
    assert {:ok, 202, _, _} = send_signed.(follow)
    assert command(b, %{op: "snapshot"})["subscription_count"] == 1
    assert command(b, %{op: "snapshot"})["subscriptions"][follow["id"]] == "pending"

    for bad <- [
          Map.put(follow, "grant", "merchant-admin"),
          Map.put(follow, "actor", beta)
        ] do
      assert {:ok, 401, _, _} = send_signed.(bad)
    end

    assert command(b, %{op: "snapshot"})["ledger"] == "locally-owned-signed-history"

    {:ok, undo} =
      FederationCore.Subscriptions.undo(alpha, follow, alpha <> "/activities/undo-1")

    assert {:ok, 202, _, _} = send_signed.(undo)
    assert command(b, %{op: "snapshot"})["subscriptions"][follow["id"]] == "withdrawn"
    stop(b)
    b2 = node(b_dir, "beta.example", b_port, "alpha.example", a_port, dir)
    on_exit(fn -> stop(b2) end)
    assert command(b2, %{op: "snapshot"})["subscriptions"][follow["id"]] == "withdrawn"
    assert command(b2, %{op: "snapshot"})["ledger"] == "locally-owned-signed-history"
    assert {:ok, 202, _, _} = send_signed.(follow)
    assert command(b2, %{op: "snapshot"})["subscriptions"][follow["id"]] == "withdrawn"
    command(b2, %{op: "block", key: "alpha.example", blocked: true})
    assert {:ok, 401, _, _} = send_signed.(follow)
  end

  # Raw HTTP/1.1 over authenticated TLS: no client library normalizes malformed
  # framing before it reaches the production Node/Bandit configuration.
  defp raw_tls(port, ca, request) do
    {:ok, socket} =
      :ssl.connect(
        ~c"localhost",
        port,
        [
          :binary,
          active: false,
          verify: :verify_peer,
          cacerts: [ca],
          server_name_indication: ~c"beta.example",
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ],
          alpn_advertised_protocols: ["http/1.1"]
        ],
        5000
      )

    try do
      :ok = :ssl.send(socket, request)
      raw_response(socket, "", System.monotonic_time(:millisecond) + 6000)
    after
      :ssl.close(socket)
    end
  end

  defp raw_response(socket, response, deadline) do
    assert byte_size(response) < 1_000_000
    remaining = deadline - System.monotonic_time(:millisecond)
    assert remaining > 0, "HTTP parser did not finish within six seconds"

    case :ssl.recv(socket, 0, remaining) do
      {:ok, bytes} -> raw_response(socket, response <> bytes, deadline)
      {:error, :closed} -> response
      other -> flunk("HTTP parser did not close bounded request: #{inspect(other)}")
    end
  end

  defp wire(headers, body) do
    "POST /actors/shop/inbox HTTP/1.1\r\nHost: beta.example\r\nConnection: close\r\n" <>
      Enum.map_join(headers, "", fn {k, v} -> "#{k}: #{v}\r\n" end) <> "\r\n" <> body
  end

  test "bounded HTTP/1.1 parser rejects ambiguous framing and preserves signed admission" do
    dir = temp()
    ca = certs(dir)
    a_port = port()
    b_port = port()
    a = node(dir <> "/alpha", "alpha.example", a_port, "beta.example", b_port, dir)
    b = node(dir <> "/beta", "beta.example", b_port, "alpha.example", a_port, dir)

    on_exit(fn ->
      stop(a)
      stop(b)
      File.rm_rf!(dir)
    end)

    # The bignum probes fit *inside* max_header_length; ordinary header limits
    # alone did not remediate GHSA-29cr-8477-rg6r.
    malformed = [
      wire([{"Content-Length", "-1"}], ""),
      wire([{"Content-Length", String.duplicate("9", 4000)}], ""),
      "GET /market HTTP/1.1\r\nHost: beta.example:" <>
        String.duplicate("9", 4000) <>
        "\r\nConnection: close\r\n\r\n",
      wire([{"Content-Length", "1"}, {"Content-Length", "2"}], "{}"),
      wire([{"Transfer-Encoding", "chunked"}, {"Content-Length", "2"}], "0\r\n\r\n"),
      wire([{"Transfer-Encoding", "chunked"}], "z\r\nx\r\n0\r\n\r\n"),
      wire([{"Transfer-Encoding", "chunked"}], "1\r\nx!\r\n0\r\n\r\n"),
      wire([{"Transfer-Encoding", "chunked"}], "1;x=\n\r\nx\r\n0\r\n\r\n"),
      wire([{"Transfer-Encoding", "chunked"}], "1;x=\r\r\nx\r\n0\r\n\r\n")
    ]

    for request <- malformed do
      # An invalid first request must close the connection without parsing the
      # appended request, even when the client asks for keep-alive.
      probe =
        String.replace(request, "Connection: close", "Connection: keep-alive") <>
          "GET /market HTTP/1.1\r\nHost: beta.example\r\nConnection: close\r\n\r\n"

      response = raw_tls(b_port, ca, probe)
      refute response =~ "200 OK"

      assert response =~ ~r/HTTP\/1\.[01] 400/,
             "unexpected malformed response: #{inspect(response)}"

      refute response =~ "HTTP/1.1 202"
      assert command(b, %{op: "snapshot"})["inbox_count"] == 0
    end

    for body <- [
          String.duplicate("x", 65_537),
          String.duplicate("1\r\nx\r\n", 65_537) <> "0\r\n\r\n"
        ] do
      headers =
        if String.starts_with?(body, "1\r\n"),
          do: [{"Transfer-Encoding", "chunked"}],
          else: [{"Content-Length", "65537"}]

      assert raw_tls(b_port, ca, wire(headers, body)) =~ "HTTP/1.1 413"
    end

    multipart =
      "--boundary\r\nContent-Disposition: form-data; name=\"activity\"\r\n\r\n{}\r\n--boundary--\r\n"

    assert raw_tls(
             b_port,
             ca,
             wire(
               [
                 {"Content-Type", "multipart/form-data; boundary=boundary"},
                 {"Content-Length", to_string(byte_size(multipart))}
               ],
               multipart
             )
           ) =~ "HTTP/1.1 401"

    assert command(b, %{op: "snapshot"})["inbox_count"] == 0

    alpha = "https://alpha.example/actors/shop"
    url = "https://beta.example/actors/shop/inbox"
    body = Jason.encode!(activity(metadata(alpha), "raw-chunked"))
    key = Signature.private!(dir <> "/alpha/signing.key")
    signed = Signature.sign(url, alpha, key, body) |> Enum.reject(fn {k, _} -> k == "host" end)
    # One-byte chunks exercise the amplification fix and must preserve the
    # exact signed bytes. Replaying the exact same signature is idempotent.
    chunked = for <<byte <- body>>, into: "", do: "1\r\n" <> <<byte>> <> "\r\n"
    request = wire(signed ++ [{"Transfer-Encoding", "chunked"}], chunked <> "0\r\n\r\n")

    for _ <- 1..2 do
      assert raw_tls(b_port, ca, request) =~ "HTTP/1.1 202"
      assert command(b, %{op: "snapshot"})["inbox_count"] == 1
    end

    assert raw_tls(
             b_port,
             ca,
             wire(signed ++ [{"Content-Length", to_string(byte_size(body) + 1)}], body <> " ")
           ) =~ "HTTP/1.1 401"

    assert command(b, %{op: "snapshot"})["inbox_count"] == 1
    assert command(b, %{op: "snapshot"})["ledger"] == "locally-owned-signed-history"

    for path <- ["/actors/shop", "/actors/shop/outbox", "/market", "/market.json"] do
      assert raw_tls(
               b_port,
               ca,
               "GET #{path} HTTP/1.1\r\nHost: beta.example\r\nConnection: close\r\n\r\n"
             ) =~ "HTTP/1.1 200"
    end

    # HTTP/2 remains disabled even after installing the fixed dependency.
    refute raw_tls(b_port, ca, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n") =~ "HTTP/2"
  end

  test "independent HTTPS nodes exchange, retry, restart, reject attacks, revise and withdraw" do
    dir = temp()
    ca = certs(dir)
    a_port = port()
    b_port = port()
    a_dir = dir <> "/alpha"
    b_dir = dir <> "/beta"
    a = node(a_dir, "alpha.example", a_port, "beta.example", b_port, dir)
    b = node(b_dir, "beta.example", b_port, "alpha.example", a_port, dir)

    on_exit(fn ->
      stop(a)
      stop(b)
      File.rm_rf!(dir)
    end)

    network = [
      test_routes: %{
        "alpha.example" => {{127, 0, 0, 1}, a_port},
        "beta.example" => {{127, 0, 0, 1}, b_port}
      },
      test_cacerts: [ca]
    ]

    alpha = "https://alpha.example/actors/shop"
    beta = "https://beta.example/actors/shop"
    am = metadata(alpha, 0, %{title: "<script>alert(1)</script> alpha part"})
    bm = metadata(beta, 0, %{title: "Beta service", price: :quote})
    assert command(a, %{op: "publish", event: "a0", metadata: am, revision: 0})["ok"]
    assert command(b, %{op: "publish", event: "b0", metadata: bm, revision: 0})["ok"]
    command(a, %{op: "deliver"})
    command(b, %{op: "deliver"})
    command(a, %{op: "drain"})
    command(b, %{op: "drain"})

    for p <- [a, b] do
      s = command(p, %{op: "snapshot"})
      assert length(s["listings"]) == 2
      assert s["ledger"] == "locally-owned-signed-history"

      assert Enum.sort(Enum.map(s["listings"], & &1["source"])) == [
               "alpha.example",
               "beta.example"
             ]
    end

    {:ok, 200, _, html} =
      Network.request(
        :get,
        "https://beta.example/market",
        [{"host", "beta.example"}],
        "",
        network
      )

    assert html =~ "&lt;script&gt;" and html =~ "alpha.example" and html =~ "beta.example"
    refute html =~ "<script>"
    # Re-deliver an identical signed activity, then attempt tampering and
    # origin/actor substitution using a valid sender key.
    key = Signature.private!(a_dir <> "/signing.key")
    a0 = activity(am, Base.encode16(:crypto.hash(:sha256, "a0"), case: :lower))
    url = beta <> "/inbox"

    send_activity = fn value ->
      body = Jason.encode!(value)
      Network.request(:post, url, Signature.sign(url, alpha, key, body), body, network)
    end

    assert {:ok, 202, _, _} = send_activity.(a0)
    assert command(b, %{op: "snapshot"})["inbox_count"] == 1

    for bad <- [
          Map.put(a0, "actor", beta),
          put_in(a0, ["object", "id"], bm["id"]),
          Map.put(a0, "command", %{"type" => "reserve_stock"}),
          Map.put(a0, "type", "Offer")
        ] do
      assert {:ok, 401, _, _} = send_activity.(bad)
    end

    body = Jason.encode!(a0)
    h = Signature.sign(url, alpha, key, body)
    assert {:ok, 401, _, _} = Network.request(:post, url, h, body <> " ", network)
    # Crash the receiver after durable enqueue but before projection.
    am1 = metadata(alpha, 1, %{title: "Revised alpha"})
    assert command(a, %{op: "publish", event: "a1", metadata: am1, revision: 1})["ok"]
    command(a, %{op: "deliver"})
    stop(b)
    b2 = node(b_dir, "beta.example", b_port, "alpha.example", a_port, dir)
    on_exit(fn -> stop(b2) end)
    command(b2, %{op: "drain"})

    assert Enum.any?(
             command(b2, %{op: "snapshot"})["listings"],
             &(&1["metadata"]["revision"] == 1)
           )

    # Partition: durable outbound work survives sender restart and eventually
    # removes the cached listing when the receiver returns.
    stop(b2)
    assert command(a, %{op: "withdraw", event: "a-delete", id: am["id"]})["ok"]
    command(a, %{op: "deliver"})
    assert command(a, %{op: "snapshot"})["pending"] == 1
    stop(a)
    a2 = node(a_dir, "alpha.example", a_port, "beta.example", b_port, dir)
    b3 = node(b_dir, "beta.example", b_port, "alpha.example", a_port, dir)

    on_exit(fn ->
      stop(a2)
      stop(b3)
    end)

    eventually(fn ->
      command(a2, %{op: "deliver"})
      command(a2, %{op: "snapshot"})["pending"] == 0
    end)

    command(b3, %{op: "drain"})
    assert command(a2, %{op: "snapshot"})["pending"] == 0
    assert length(command(b3, %{op: "snapshot"})["listings"]) == 1
    # A re-signed delayed Create cannot resurrect a withdrawn listing.
    assert {:ok, 202, _, _} = send_activity.(a0)
    command(b3, %{op: "drain"})
    assert length(command(b3, %{op: "snapshot"})["listings"]) == 1
    assert command(b3, %{op: "snapshot"})["ledger"] == "locally-owned-signed-history"
    # Current actor document is fetched on every authentication: old keys
    # become unusable on a TLS-authenticated actor-key rotation.
    stop(a2)
    replacement = key()

    File.write!(
      a_dir <> "/signing.key",
      :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, replacement)])
    )

    a3 = node(a_dir, "alpha.example", a_port, "beta.example", b_port, dir)
    on_exit(fn -> stop(a3) end)
    assert {:ok, 401, _, _} = send_activity.(a0)
    body = Jason.encode!(a0)

    assert {:ok, 202, _, _} =
             Network.request(
               :post,
               url,
               Signature.sign(url, alpha, replacement, body),
               body,
               network
             )

    command(b3, %{op: "block", key: "alpha.example", blocked: true})

    assert {:ok, 401, _, _} =
             Network.request(
               :post,
               url,
               Signature.sign(url, alpha, replacement, body),
               body,
               network
             )
  end

  test "a late peer gets current listings and withdrawals; obsolete retries never bootstrap" do
    dir = temp()
    certs(dir)
    a_port = port()
    b_port = port()
    alpha = "https://alpha.example/actors/shop"
    beta = "https://beta.example/actors/shop"
    a_dir = dir <> "/alpha"
    b_dir = dir <> "/beta"
    a = node(a_dir, "alpha.example", a_port, "beta.example", b_port, dir, [])
    b = node(b_dir, "beta.example", b_port, "alpha.example", a_port, dir)

    on_exit(fn ->
      stop(a)
      stop(b)
      File.rm_rf!(dir)
    end)

    m0 = metadata(alpha)
    m2 = metadata(alpha, 2, %{title: "Current revision"})
    gone = metadata(alpha, 0, %{listing_id: "https://alpha.example/listings/gone"})
    hidden = metadata(alpha, 0, %{listing_id: "https://alpha.example/listings/hidden"})
    assert command(a, %{op: "publish", event: "initial", metadata: m0, revision: 0})["ok"]
    assert command(a, %{op: "publish", event: "current", metadata: m2, revision: 2})["ok"]
    assert command(a, %{op: "publish", event: "gone-create", metadata: gone, revision: 0})["ok"]
    assert command(a, %{op: "withdraw", event: "gone-delete", id: gone["id"]})["ok"]
    assert command(a, %{op: "publish", event: "hidden", metadata: hidden, revision: 0})["ok"]
    command(a, %{op: "block", key: hidden["id"], blocked: true})
    assert command(a, %{op: "snapshot"})["pending"] == 0
    stop(a)

    a2 = node(a_dir, "alpha.example", a_port, "beta.example", b_port, dir, [beta])
    on_exit(fn -> stop(a2) end)
    assert command(a2, %{op: "reconcile"})["stats"]["inserted"] == 2
    # An identical accepted source event stays a duplicate after peering changes.
    assert command(a2, %{op: "publish", event: "initial", metadata: m0, revision: 0})["status"] ==
             "duplicate"

    command(a2, %{op: "deliver"})
    command(b, %{op: "drain"})
    s = command(b, %{op: "snapshot"})
    assert s["inbox_count"] == 2 and s["remote_withdrawn"] == 1
    assert [%{"metadata" => %{"revision" => 2, "name" => "Current revision"}}] = s["listings"]
    assert command(a2, %{op: "reconcile"})["stats"]["inserted"] == 0
    command(a2, %{op: "deliver"})
    assert command(b, %{op: "snapshot"})["inbox_count"] == 2

    stop(b)

    for revision <- [3, 4] do
      assert command(a2, %{
               op: "publish",
               event: "rev-#{revision}",
               metadata: metadata(alpha, revision),
               revision: revision
             })["ok"]
    end

    assert command(a2, %{op: "withdraw", event: "final-delete", id: m0["id"]})["ok"]
    command(a2, %{op: "deliver"})
    assert command(a2, %{op: "snapshot"})["superseded"] == 2
    assert command(a2, %{op: "snapshot"})["pending"] == 1
    stop(a2)

    a3 = node(a_dir, "alpha.example", a_port, "beta.example", b_port, dir)
    b2 = node(b_dir, "beta.example", b_port, "alpha.example", a_port, dir)

    on_exit(fn ->
      stop(a3)
      stop(b2)
    end)

    eventually(fn ->
      command(a3, %{op: "deliver"})
      command(a3, %{op: "snapshot"})["pending"] == 0
    end)

    command(b2, %{op: "drain"})
    s = command(b2, %{op: "snapshot"})
    assert s["inbox_count"] == 3 and s["remote_withdrawn"] == 2 and s["listings"] == []
    assert s["ledger"] == "locally-owned-signed-history"
  end

  test "explicit redelivery repairs a peer's lost cache using authenticated current snapshots",
    do: repair_cache()

  defp repair_cache do
    dir = temp()
    certs(dir)
    a_port = port()
    b_port = port()
    alpha = "https://alpha.example/actors/shop"
    beta = "https://beta.example/actors/shop"
    a_dir = dir <> "/alpha"
    b_dir = dir <> "/beta"
    a = node(a_dir, "alpha.example", a_port, "beta.example", b_port, dir)
    b = node(b_dir, "beta.example", b_port, "alpha.example", a_port, dir)

    on_exit(fn ->
      stop(a)
      stop(b)
      File.rm_rf!(dir)
    end)

    gone = metadata(alpha, 0, %{listing_id: "https://alpha.example/listings/gone"})

    assert command(a, %{op: "publish", event: "first", metadata: metadata(alpha), revision: 0})[
             "ok"
           ]

    assert command(a, %{
             op: "publish",
             event: "current",
             metadata: metadata(alpha, 3),
             revision: 3
           })["ok"]

    assert command(a, %{op: "publish", event: "gone", metadata: gone, revision: 0})["ok"]
    assert command(a, %{op: "withdraw", event: "delete", id: gone["id"]})["ok"]
    command(a, %{op: "deliver"})
    command(b, %{op: "drain"})
    old = command(b, %{op: "snapshot"})
    assert old["inbox_count"] == 2 and old["remote_withdrawn"] == 1
    assert command(a, %{op: "snapshot"})["pending"] == 0

    # Simulate losing only a receiver discovery journal. Its independently
    # managed keys and business history remain; no home publication is stored
    # on this receiver. This operation is deliberately outside the service API.
    stop(b)
    File.rm!(b_dir <> "/discovery.log")
    b_key = File.read!(b_dir <> "/signing.key")
    b2 = node(b_dir, "beta.example", b_port, "alpha.example", a_port, dir)
    on_exit(fn -> stop(b2) end)
    assert command(b2, %{op: "snapshot"})["inbox_count"] == 0
    command(a, %{op: "deliver"})
    assert command(b2, %{op: "snapshot"})["inbox_count"] == 0

    # A trusted sender administrator requests repair. Persist the generation
    # before any requeue; then restart the sender and partition the receiver.
    assert command(a, %{op: "redeliver", peer: beta}) == %{"ok" => true, "status" => "1"}
    stop(a)
    stop(b2)
    a2 = node(a_dir, "alpha.example", a_port, "beta.example", b_port, dir)
    on_exit(fn -> stop(a2) end)
    assert command(a2, %{op: "reconcile"})["stats"]["requeued"] == 2
    command(a2, %{op: "deliver"})
    assert command(a2, %{op: "snapshot"})["pending"] == 2
    b3 = node(b_dir, "beta.example", b_port, "alpha.example", a_port, dir)
    on_exit(fn -> stop(b3) end)

    eventually(fn ->
      command(a2, %{op: "deliver"})
      command(a2, %{op: "snapshot"})["pending"] == 0
    end)

    command(b3, %{op: "drain"})
    repaired = command(b3, %{op: "snapshot"})
    assert repaired["inbox_count"] == 2 and repaired["remote_withdrawn"] == 1

    assert [%{"metadata" => %{"revision" => 3}, "source" => "alpha.example"}] =
             repaired["listings"]

    assert repaired["listings"] |> Enum.map(& &1["activity_id"]) ==
             old["listings"] |> Enum.map(& &1["activity_id"])

    assert repaired["ledger"] == "locally-owned-signed-history"
    assert File.read!(b_dir <> "/signing.key") == b_key

    # Repeating the explicit operation is another generation, with ordinary
    # activity deduplication at a receiver that already holds those IDs.
    assert command(a2, %{op: "redeliver", peer: beta})["status"] == "2"
    command(a2, %{op: "deliver"})
    command(b3, %{op: "drain"})
    duplicate = command(b3, %{op: "snapshot"})
    assert duplicate["inbox_count"] == repaired["inbox_count"]
    assert duplicate["listings"] == repaired["listings"]
    assert command(a2, %{op: "snapshot"})["ledger"] == "locally-owned-signed-history"
  end
end
