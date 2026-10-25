defmodule FederationService.GossipTest do
  use ExUnit.Case, async: true
  alias FederationService.{Gossip, Store}
  import FederationService.TestHelpers
  @alpha "https://alpha.example/actors/shop"
  @beta "https://beta.example/actors/shop"

  setup do
    dir = temp()
    {:ok, store} = Store.start_link(directory: dir)
    sa = :crypto.strong_rand_bytes(32)
    sb = :crypto.strong_rand_bytes(32)

    public = fn seed ->
      {key, _} = :crypto.generate_key(:eddsa, :ed25519, seed)
      Base.encode16(key, case: :lower)
    end

    keys = %{@alpha => public.(sa), @beta => public.(sb)}

    scope = %{
      "halaqa_id" => "public-market",
      "charter_hash" => String.duplicate("a", 64),
      "epoch" => 1
    }

    service = FederationService.config!(actor: @beta, private_key: nil, store: store)

    sender =
      Gossip.config!(%{service | actor: @alpha}, scope: scope, seed: sa, publisher_keys: keys)

    receiver = Gossip.config!(service, scope: scope, seed: sb, publisher_keys: keys)

    on_exit(fn ->
      stop_store(store)
      File.rm_rf!(dir)
    end)

    %{store: store, dir: dir, sender: sender, receiver: receiver}
  end

  defp wire(sender, revision \\ 0, id \\ "first") do
    m = metadata(@alpha, revision)

    {:ok, wire} =
      Gossip.encode(sender, activity(m, id, if(revision == 0, do: :create, else: :update)), m)

    wire
  end

  defp sign(config, envelope) do
    bytes =
      Enum.join(
        [
          envelope["schema"],
          envelope["halaqa_id"],
          envelope["charter_hash"],
          envelope["epoch"],
          envelope["publisher"],
          envelope["announcement"],
          envelope["payload"]
        ],
        "\n"
      )

    signature = :crypto.sign(:eddsa, :none, bytes, [config.seed, :ed25519]) |> Base.encode64()
    envelope |> Map.put("signature", signature) |> Jason.encode!()
  end

  test "origin signature and exact scope survive forwarding; a relay's identity grants no authorship",
       c do
    raw = wire(c.sender)
    assert {:ok, %{actor: @alpha}, _, _, _} = Gossip.decode(c.receiver, raw)
    envelope = Jason.decode!(raw)

    for {field, value} <- [
          {"payload", Base.encode64("{}")},
          {"publisher", c.receiver.publisher},
          {"signature", Base.encode64(<<0::512>>)},
          {"halaqa_id", "another-circle"},
          {"epoch", 2},
          {"charter_hash", String.duplicate("b", 64)}
        ] do
      assert {:error, :gossip_refused} =
               Gossip.decode(c.receiver, envelope |> Map.put(field, value) |> Jason.encode!())
    end

    assert {:error, :gossip_refused} =
             Gossip.decode(
               c.receiver,
               sign(c.receiver, Map.put(envelope, "publisher", c.receiver.publisher))
             )

    assert {:error, :gossip_refused} = Gossip.decode(c.receiver, String.duplicate("x", 65_537))

    assert {:error, :gossip_refused} =
             Gossip.decode(
               c.receiver,
               raw |> Jason.decode!() |> Map.put("command", "reserve_stock") |> Jason.encode!()
             )

    assert Gossip.topic(c.sender) == Gossip.topic(c.receiver)

    refute Gossip.topic(c.sender) ==
             Gossip.topic(%{c.sender | scope: Map.put(c.sender.scope, "epoch", 2)})
  end

  test "a valid transport key cannot substitute seller origins or metadata identifiers", c do
    envelope = wire(c.sender) |> Jason.decode!()
    payload = envelope["payload"] |> Base.decode64!() |> Jason.decode!()

    for bad <- [
          put_in(payload, ["activity", "object", "id"], "https://other.example/listings/x"),
          put_in(payload, ["metadata", "id"], "https://alpha.example/listings/different"),
          put_in(payload, ["activity", "actor"], @beta),
          put_in(payload, ["metadata", "price", "minor_units"], 1.5)
        ] do
      forged = Map.put(envelope, "payload", bad |> Jason.encode!() |> Base.encode64())
      assert {:error, :gossip_refused} = Gossip.decode(c.receiver, sign(c.sender, forged))
    end

    assert Store.call(c.store, :snapshot).events == %{}
  end

  test "durable receipt, monotone revisions and terminal withdrawal recover without remote fetching",
       c do
    raw = wire(c.sender)
    assert {:ok, :queued} = Gossip.receive_event(c.receiver, raw, 1000)
    GenServer.stop(c.store)
    {:ok, store} = Store.start_link(directory: c.dir)
    receiver = %{c.receiver | service: %{c.receiver.service | store: store}}
    assert {:ok, :duplicate} = Gossip.receive_event(receiver, raw, 1001)
    Gossip.drain(receiver, 1002)

    assert [%{metadata: %{"revision" => 0}, verified_at: 1002}] =
             FederationService.search(receiver.service, "", 1003)

    assert {:ok, :queued} = Gossip.receive_event(receiver, wire(c.sender, 2, "second"), 1003)
    Gossip.drain(receiver, 1004)
    assert {:ok, :queued} = Gossip.receive_event(receiver, wire(c.sender, 1, "stale"), 1005)
    Gossip.drain(receiver, 1006)

    assert [%{metadata: %{"revision" => 2}, verified_at: 1004}] =
             FederationService.search(receiver.service, "", 1007)

    {:ok, del} =
      FederationCore.Marketplace.withdraw(
        @alpha,
        metadata()["id"],
        @alpha <> "/activities/delete"
      )

    {:ok, withdrawal} = Gossip.encode(c.sender, del, nil)
    assert {:ok, :queued} = Gossip.receive_event(receiver, withdrawal, 1008)
    Gossip.drain(receiver, 1009)
    assert {:ok, :queued} = Gossip.receive_event(receiver, wire(c.sender, 3, "late"), 1010)
    Gossip.drain(receiver, 1011)
    assert FederationService.search(receiver.service) == []
    data = Store.call(store, :snapshot)
    assert data.remote[metadata()["id"]].withdrawn
    assert data.events == %{} and data.local == %{} and data.outbox == %{}
    GenServer.stop(store)
  end

  test "same activity ID with changed signed metadata conflicts; duplicate receipts never renew freshness",
       c do
    raw = wire(c.sender)
    Gossip.receive_event(c.receiver, raw, 1000)
    Gossip.drain(c.receiver, 1001)
    assert {:ok, :duplicate} = Gossip.receive_event(c.receiver, raw, 2000)
    fresh_announcement = wire(c.sender)
    refute fresh_announcement == raw
    assert {:ok, :duplicate} = Gossip.receive_event(c.receiver, fresh_announcement, 2000)
    Gossip.drain(c.receiver, 2001)
    assert Store.call(c.store, :snapshot).remote[metadata()["id"]].verified_at == 1001
    envelope = Jason.decode!(raw)

    payload =
      envelope["payload"]
      |> Base.decode64!()
      |> Jason.decode!()
      |> put_in(["metadata", "revision"], 2)

    changed = Map.put(envelope, "payload", payload |> Jason.encode!() |> Base.encode64())

    assert {:error, :activity_conflict} =
             Gossip.receive_event(c.receiver, sign(c.sender, changed), 2002)
  end

  test "queued work rechecks revoked origin pins and current moderation", c do
    raw = wire(c.sender)
    Gossip.receive_event(c.receiver, raw, 1000)

    changed = %{
      c.receiver
      | publisher_keys: Map.put(c.receiver.publisher_keys, @alpha, c.receiver.publisher)
    }

    Gossip.drain(changed, 1001)

    assert Store.call(c.store, :snapshot).gossip_inbox[@alpha <> "/activities/first"].status ==
             {:rejected, :publisher_revoked}

    assert {:error, :gossip_refused} = Gossip.receive_event(changed, raw, 1002)
    Gossip.receive_event(c.receiver, wire(c.sender, 1, "blocked"), 1003)
    Store.call(c.store, {:block, "alpha.example", true})
    Gossip.drain(c.receiver, 1004)
    assert Store.call(c.store, :snapshot).remote == %{}
    assert {:error, :gossip_refused} = Gossip.receive_event(c.receiver, raw, 1005)
  end

  test "only current local public projections are broadcast; moderation holds ads but allows tombstones",
       c do
    config = c.sender.service
    FederationService.publish(config, "first", metadata())
    FederationService.publish(config, "current", metadata(@alpha, 2), :update)
    [{id, _}] = Gossip.frames(c.sender, 1000)
    assert Store.call(c.store, :snapshot).local[metadata()["id"]].activity_id == id
    Store.call(c.store, {:gossip_sent, Gossip.topic(c.sender), id, 1000})
    assert Gossip.frames(c.sender, 1029) == []
    assert [{^id, _}] = Gossip.frames(c.sender, 1030)
    Store.call(c.store, {:block, metadata()["id"], true})
    refute Gossip.current?(c.sender, id)
    assert Gossip.frames(c.sender, 1031) == []
    FederationService.withdraw(config, "delete", metadata()["id"])
    assert [{_, withdrawal}] = Gossip.frames(c.sender, 1032)

    assert Jason.decode!(withdrawal)["payload"]
           |> Base.decode64!()
           |> Jason.decode!()
           |> get_in(["activity", "type"]) == "Delete"

    assert Gossip.frames(c.receiver, 1032) == []
  end

  test "commit notifications are coalesced and only wake subscribers after durable publication",
       c do
    :ok = Store.call(c.store, :subscribe)

    for n <- 0..2,
        do:
          FederationService.publish(
            c.sender.service,
            "e#{n}",
            metadata(@alpha, n),
            if(n == 0, do: :create, else: :update)
          )

    assert_receive {:discovery_committed, store}
    assert store == c.store
    refute_receive {:discovery_committed, _}
    :ok = Store.call(c.store, :notifications_received)
    FederationService.withdraw(c.sender.service, "withdraw", metadata()["id"])
    assert_receive {:discovery_committed, ^store}
    assert Store.call(c.store, :snapshot).local[metadata()["id"]].withdrawn
  end

  test "HTTP and gossip receipts share activity-ID refusal without cross-transport mutation", c do
    m = metadata()
    a = activity(m)
    assert {:ok, :queued} = enqueue(c.store, a)
    assert :ok = Store.call(c.store, {:project, a["id"], m, 1000})
    assert {:ok, wire} = Gossip.encode(c.sender, a, metadata(@alpha, 2))
    assert {:ok, :duplicate} = Gossip.receive_event(c.receiver, wire, 1001)
    Gossip.drain(c.receiver, 1002)
    assert Store.call(c.store, :snapshot).remote[m["id"]].metadata["revision"] == 0
    b = activity(metadata(@alpha, 3), "three", :update)
    {:ok, wire} = Gossip.encode(c.sender, b, metadata(@alpha, 3))
    assert {:ok, :queued} = Gossip.receive_event(c.receiver, wire, 1003)
    assert {:ok, :duplicate} = enqueue(c.store, b)
    changed = put_in(b, ["object", "name"], "different")
    assert {:error, :activity_conflict} = enqueue(c.store, changed)
    Gossip.drain(c.receiver, 1004)
    assert Store.call(c.store, :snapshot).remote[m["id"]].metadata["revision"] == 3
  end

  test "revoked pins and changed circle epochs hide accepted results; signed float epochs are refused",
       c do
    raw = wire(c.sender)
    Gossip.receive_event(c.receiver, raw, 1000)
    Gossip.drain(c.receiver, 1001)
    assert [_] = FederationService.search(c.receiver.service)
    keys = Map.delete(c.receiver.publisher_keys, @alpha)

    revoked =
      Gossip.config!(c.receiver.service,
        scope: c.receiver.scope,
        seed: c.receiver.seed,
        publisher_keys: keys
      )

    assert [] = FederationService.search(revoked.service)
    epoch = Map.put(c.receiver.scope, "epoch", 2)

    changed =
      Gossip.config!(c.receiver.service,
        scope: epoch,
        seed: c.receiver.seed,
        publisher_keys: c.receiver.publisher_keys
      )

    assert [] = FederationService.search(changed.service)
    signed_float = raw |> Jason.decode!() |> Map.put("epoch", 1.0)
    assert {:error, :gossip_refused} = Gossip.decode(c.receiver, sign(c.sender, signed_float))
  end

  test "combined market UI shows pinned gossip and local sources without an HTTP actor key", c do
    Gossip.receive_event(c.receiver, wire(c.sender), 1000)
    Gossip.drain(c.receiver, 1001)
    FederationService.publish(c.receiver.service, "local", metadata(@beta))

    request = fn path ->
      Plug.Test.conn(:get, path)
      |> Map.put(:host, "beta.example")
      |> Map.update!(:req_headers, &[{"host", "beta.example"} | &1])
      |> FederationService.Router.call(c.receiver.service)
    end

    assert request.("/actors/shop").status == 404
    html = request.("/market").resp_body
    assert html =~ "alpha.example" and html =~ "beta.example"
    listings = request.("/market.json").resp_body |> Jason.decode!() |> Map.fetch!("listings")
    assert length(listings) == 2
    remote = Enum.find(listings, &(&1["actor"] == @alpha))
    assert remote["transport"] == "iroh-gossip" and remote["publisher_key"] == c.sender.publisher
    assert remote["halaqa_scope"] == c.receiver.scope
  end

  test "repair rotates least recently announced snapshots so retained tombstones cannot starve new ads",
       c do
    for n <- 1..20 do
      listing = "https://alpha.example/listings/gone-#{n}"
      FederationService.withdraw(c.sender.service, "delete-#{n}", listing)
    end

    for {_, row} <- Store.call(c.store, :snapshot).local do
      Store.call(c.store, {:gossip_sent, Gossip.topic(c.sender), row.activity_id, 1000})
    end

    FederationService.publish(c.sender.service, "new", metadata())
    [{id, _} | _] = Gossip.frames(c.sender, 2000)
    assert id == Store.call(c.store, :snapshot).local[metadata()["id"]].activity_id
    assert length(Gossip.frames(c.sender, 2000)) == 16
  end

  test "HTTP refresh never fetches or renews a signed inline gossip projection", c do
    Gossip.receive_event(c.receiver, wire(c.sender), 1000)
    Gossip.drain(c.receiver, 1001)
    before = Store.call(c.store, :snapshot).remote[metadata()["id"]]
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)

    accept =
      Task.async(fn ->
        case :gen_tcp.accept(listener, 500) do
          {:ok, socket} ->
            :gen_tcp.close(socket)
            :unexpected_connection

          error ->
            error
        end
      end)

    service = %{
      c.receiver.service
      | peers: [@alpha],
        network: [test_routes: %{"alpha.example" => {{127, 0, 0, 1}, port}}]
    }

    FederationService.refresh(service, 2000)
    assert Task.await(accept, 1500) == {:error, :timeout}
    assert Store.call(c.store, :snapshot).remote[metadata()["id"]] == before
    Store.call(c.store, {:refresh, metadata()["id"], before.metadata, 3000})
    assert Store.call(c.store, :snapshot).remote[metadata()["id"]] == before
  end

  test "a changed circle worker cannot reject queued evidence for the original circle", c do
    Gossip.receive_event(c.receiver, wire(c.sender), 1000)
    other = %{c.receiver | scope: Map.put(c.receiver.scope, "halaqa_id", "other-circle")}
    Gossip.drain(other, 1001)

    assert Store.call(c.store, :snapshot).gossip_inbox[@alpha <> "/activities/first"].status ==
             :pending

    Gossip.drain(c.receiver, 1002)
    assert [_] = FederationService.search(c.receiver.service)
  end

  test "a Store permits one gossip worker and releases ownership when that process exits", c do
    parent = self()

    owner =
      spawn(fn ->
        :ok = Store.call(c.store, :claim_gossip_worker)
        send(parent, :claimed)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :claimed
    assert {:error, :gossip_worker_exists} = Store.call(c.store, :claim_gossip_worker)
    monitor = Process.monitor(owner)
    send(owner, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}

    result =
      Enum.reduce_while(1..50, nil, fn _, _ ->
        case Store.call(c.store, :claim_gossip_worker) do
          :ok ->
            {:halt, :ok}

          _ ->
            Process.sleep(10)
            {:cont, nil}
        end
      end)

    assert result == :ok
  end
end
