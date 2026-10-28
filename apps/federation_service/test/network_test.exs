defmodule FederationService.TestPeer do
  import Plug.Conn
  def init(state), do: state

  def call(conn, state) do
    conn =
      if conn.method == "POST" do
        {:ok, body, conn} = read_body(conn)
        activity = Jason.decode!(body)

        Agent.update(state, fn doc ->
          doc
          |> Map.update(:received, 1, &(&1 + 1))
          |> Map.update(:deliveries, [activity], &(&1 ++ [activity]))
        end)

        conn
      else
        conn
      end

    case conn.request_path do
      "/redirect" ->
        conn |> put_resp_header("location", "https://127.0.0.1/private") |> send_resp(302, "")

      "/large" ->
        send_resp(conn, 200, String.duplicate("a", 65_537))

      "/compressed" ->
        conn |> put_resp_header("content-encoding", "gzip") |> send_resp(200, "compressed")

      "/chunked" ->
        conn = send_chunked(conn, 200)
        {:ok, conn} = chunk(conn, "{}")
        conn

      "/slow" ->
        Process.sleep(6000)
        send_resp(conn, 200, "{}")

      "/duplicate" ->
        conn |> Map.put(:resp_headers, [{"date", "a"}, {"date", "b"}]) |> send_resp(200, "{}")

      "/actors/shop" ->
        conn
        |> put_resp_content_type("application/activity+json")
        |> send_resp(
          200,
          Jason.encode!(Agent.get(state, &Map.drop(&1, [:received, :deliveries])))
        )

      _ ->
        conn |> put_resp_content_type("application/json") |> send_resp(200, "{}")
    end
  end
end

defmodule FederationService.NetworkTest do
  use ExUnit.Case, async: false
  import FederationService.TestHelpers
  alias FederationService.{Network, Signature}

  setup_all do
    dir = temp()
    ca = certs(dir)

    {:ok, state} =
      Agent.start_link(fn -> Signature.actor("https://alpha.example/actors/shop", key()) end)

    {:ok, server} =
      Bandit.start_link(
        plug: {FederationService.TestPeer, state},
        scheme: :https,
        ip: {127, 0, 0, 1},
        port: 0,
        certfile: dir <> "/alpha.example.pem",
        keyfile: dir <> "/alpha.example.key",
        startup_log: false
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    network = [
      test_routes: %{
        "alpha.example" => {{127, 0, 0, 1}, port},
        "beta.example" => {{127, 0, 0, 1}, port}
      },
      test_cacerts: [ca]
    ]

    Process.unlink(server)
    Process.unlink(state)

    on_exit(fn ->
      try do
        if Process.alive?(server), do: GenServer.stop(server)
        if Process.alive?(state), do: Agent.stop(state)
      catch
        :exit, _ -> :ok
      end

      File.rm_rf!(dir)
    end)

    %{network: network, state: state}
  end

  test "real TLS validates certificate chain and requested hostname", c do
    assert {:ok, %{}} = Network.json("https://alpha.example/ok", c.network)
    assert {:error, _} = Network.json("https://beta.example/ok", c.network)

    assert {:error, _} =
             Network.json("https://alpha.example/ok", Keyword.put(c.network, :test_cacerts, []))
  end

  test "redirects, oversized responses, compressed/chunked payloads, duplicate headers and slow streams fail closed",
       c do
    for route <- ~w(redirect large compressed chunked duplicate slow) do
      assert {:error, _} = Network.json("https://alpha.example/" <> route, c.network)
    end
  end

  test "listing moderation holds pending advertisements while withdrawals can still deliver", c do
    dir = temp()
    {:ok, store} = FederationService.Store.start_link(directory: dir)

    on_exit(fn ->
      stop_store(store)
      File.rm_rf!(dir)
    end)

    config =
      FederationService.config!(
        actor: "https://beta.example/actors/shop",
        private_key: key(),
        store: store,
        peers: ["https://alpha.example/actors/shop"],
        network: c.network
      )

    m = metadata(config.actor)
    assert {:ok, :published} = FederationService.publish(config, "source", m)
    FederationService.Store.call(store, {:block, m["id"], true})
    initial = Agent.get(c.state, &Map.get(&1, :received, 0))
    FederationService.deliver(config)
    assert Agent.get(c.state, &Map.get(&1, :received, 0)) == initial
    assert {:ok, :published} = FederationService.withdraw(config, "withdraw", m["id"])
    FederationService.deliver(config, System.system_time(:second) + 3)
    assert Agent.get(c.state, &Map.get(&1, :received, 0)) == initial + 1
    rows = FederationService.Store.call(store, :snapshot).outbox |> Map.values()
    assert Enum.find(rows, &(&1.activity["type"] == "Delete")).status == :delivered
    assert Enum.find(rows, &(&1.activity["type"] == "Create")).status == :superseded
  end

  test "withdrawals are delivered before a bulk late-peer backfill", c do
    dir = temp()
    {:ok, store} = FederationService.Store.start_link(directory: dir)

    on_exit(fn ->
      stop_store(store)
      File.rm_rf!(dir)
    end)

    config =
      FederationService.config!(
        actor: "https://beta.example/actors/shop",
        private_key: key(),
        store: store,
        peers: [],
        network: c.network
      )

    for n <- 1..17 do
      m = metadata(config.actor, 0, %{listing_id: "https://beta.example/listings/part-#{n}"})
      FederationService.publish(config, "bulk-#{n}", m)
    end

    m = metadata(config.actor, 0, %{listing_id: "https://beta.example/listings/withdrawn"})
    FederationService.publish(config, "obsolete", m)
    FederationService.withdraw(config, "withdrawal", m["id"])
    before = Agent.get(c.state, &length(Map.get(&1, :deliveries, [])))
    FederationService.deliver(%{config | peers: ["https://alpha.example/actors/shop"]})
    batch = Agent.get(c.state, &Map.get(&1, :deliveries, [])) |> Enum.drop(before)
    assert length(batch) == 16
    assert hd(batch)["type"] == "Delete"
    assert Enum.all?(tl(batch), &(&1["type"] == "Create"))
  end

  test "actor identity and exact key ownership come from current HTTPS document", c do
    actor = "https://alpha.example/actors/shop"
    original = Agent.get(c.state, & &1)
    assert {:ok, _} = Signature.discover(actor, c.network)

    bad_docs = [
      Map.put(original, "id", "https://evil.example/actors/shop"),
      put_in(original, ["publicKey", "owner"], "https://evil.example/actors/shop"),
      put_in(original, ["publicKey", "id"], "https://evil.example/key"),
      put_in(original, ["publicKey", "publicKeyPem"], "garbage"),
      Map.put(original, "inbox", "https://evil.example/inbox")
    ]

    for bad <- bad_docs do
      Agent.update(c.state, fn _ -> bad end)
      assert {:error, :invalid_actor} = Signature.discover(actor, c.network)
    end

    Agent.update(c.state, fn _ -> original end)
  end
end
