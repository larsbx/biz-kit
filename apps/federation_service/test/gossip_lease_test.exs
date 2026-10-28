defmodule FederationService.GossipLeaseTest do
  use ExUnit.Case, async: true
  alias FederationService.{Gossip, GossipLease, GossipSync, Store}
  import FederationService.TestHelpers
  @alpha "https://alpha.example/actors/shop"
  @beta "https://beta.example/actors/shop"

  setup do
    dir = temp()
    {:ok, a} = Store.start_link(directory: dir <> "/a")
    {:ok, b} = Store.start_link(directory: dir <> "/b")
    seeds = %{@alpha => :crypto.strong_rand_bytes(32), @beta => :crypto.strong_rand_bytes(32)}

    keys =
      Map.new(seeds, fn {actor, seed} ->
        {public, _} = :crypto.generate_key(:eddsa, :ed25519, seed)
        {actor, Base.encode16(public, case: :lower)}
      end)

    scope = %{"halaqa_id" => "market", "charter_hash" => String.duplicate("a", 64), "epoch" => 1}

    make = fn actor, store ->
      Gossip.config!(FederationService.config!(actor: actor, private_key: nil, store: store),
        seed: seeds[actor],
        publisher_keys: keys,
        scope: scope
      )
    end

    assert {:ok, :published} =
             FederationService.publish(make.(@alpha, a).service, "source-0", metadata())

    id = Store.call(a, :snapshot).local[metadata()["id"]].activity_id

    on_exit(fn ->
      stop_store(a)
      stop_store(b)
      File.rm_rf!(dir)
    end)

    %{a: make.(@alpha, a), b: make.(@beta, b), id: id, dir: dir}
  end

  defp project(c, at \\ 1000) do
    [{_, wire}] = Gossip.frames(c.a, at)
    assert {:ok, :queued} = Gossip.receive_event(c.b, wire, at)
    Gossip.drain(c.b, at)
  end

  defp wire(a, at) do
    [{_, wire}] = GossipLease.frames(a, at, MapSet.new())
    wire
  end

  defp strict(config) do
    Gossip.config!(config.service,
      seed: config.seed,
      publisher_keys: config.publisher_keys,
      scope: config.scope,
      require_freshness_lease: true
    )
  end

  test "lease policy is explicit, validated and independent of topic identity", c do
    refute c.b.service.gossip_policy.require_freshness_lease
    assert strict(c.b).service.gossip_policy.require_freshness_lease
    assert Gossip.topic(strict(c.b)) == Gossip.topic(c.b)

    for invalid <- [nil, "true", 1, :required] do
      assert_raise MatchError, fn ->
        Gossip.config!(c.b.service,
          seed: c.b.seed,
          publisher_keys: c.b.publisher_keys,
          scope: c.b.scope,
          require_freshness_lease: invalid
        )
      end
    end
  end

  test "a cold strict receiver never grants freshness to a replayed advertisement", c do
    {:ok, _} = GossipLease.renew(c.a, c.id, 60, 1000)
    expired = wire(c.a, 1000)
    c = %{c | b: strict(c.b)}
    project(c, 5000)

    assert [%{stale: true, freshness_source: "none", freshness_expires_at: nil}] =
             FederationService.search(c.b.service, "", 5000)

    assert {:error, :lease_refused} = GossipLease.receive_event(c.b, expired, 5000)
    [{_, replay}] = Gossip.frames(c.a, 5001)
    assert {:ok, :duplicate} = Gossip.receive_event(c.b, replay, 5001)
    Gossip.drain(c.b, 5001)
    Store.call(c.b.service.store, {:refresh, metadata()["id"], metadata(), 5001})
    assert [%{stale: true, verified_at: 5000}] = FederationService.search(c.b.service, "", 5001)

    # Compatibility is a local choice over the same durable projection.
    compatibility = %{
      c.b.service
      | gossip_policy: %{c.b.service.gossip_policy | require_freshness_lease: false}
    }

    assert [%{stale: false, freshness_source: "projection"}] =
             FederationService.search(compatibility, "", 5001)

    before = Store.call(c.b.service.store, :snapshot)
    assert {:ok, _} = GossipLease.renew(c.a, c.id, 60, 5002)
    assert {:ok, :accepted} = GossipLease.receive_event(c.b, wire(c.a, 5002), 5002)

    assert [%{stale: false, freshness_source: "publisher_lease", verified_at: 5000}] =
             FederationService.search(c.b.service, "", 5002)

    assert [%{stale: true, freshness_expires_at: 5062}] =
             FederationService.search(c.b.service, "", 5062)

    assert Store.call(c.b.service.store, :snapshot).remote == before.remote
  end

  test "strict policy survives receiver restart and requires a lease for each new revision", c do
    c = %{c | b: strict(c.b)}
    project(c)
    GenServer.stop(c.b.service.store)
    {:ok, b} = Store.start_link(directory: c.dir <> "/b")
    on_exit(fn -> stop_store(b) end)
    c = %{c | b: %{c.b | service: %{c.b.service | store: b}}}

    assert [%{stale: true, freshness_source: "none"}] =
             FederationService.search(c.b.service, "", 1001)

    assert {:ok, _} = GossipLease.renew(c.a, c.id, 300, 1001)
    old = wire(c.a, 1001)
    assert {:ok, :accepted} = GossipLease.receive_event(c.b, old, 1001)

    assert {:ok, :published} =
             FederationService.publish(c.a.service, "source-1", metadata(@alpha, 1), :update)

    project(c, 1002)

    assert [%{stale: true, freshness_source: "none", metadata: %{"revision" => 1}}] =
             FederationService.search(c.b.service, "", 1002)

    assert {:error, :lease_refused} = GossipLease.receive_event(c.b, old, 1002)
    id = Store.call(c.a.service.store, :snapshot).local[metadata()["id"]].activity_id
    assert {:ok, %{"sequence" => 2}} = GossipLease.renew(c.a, id, 60, 1003)
    assert {:ok, :accepted} = GossipLease.receive_event(c.b, wire(c.a, 1003), 1003)

    assert [%{stale: false, freshness_source: "publisher_lease"}] =
             FederationService.search(c.b.service, "", 1003)
  end

  test "requiring gossip leases preserves local and HTTP projection freshness", c do
    assert [%{local: true, stale: false, freshness_source: "projection"}] =
             FederationService.search(strict(c.a).service)

    activity = Store.call(c.a.service.store, :snapshot).publications[c.id]
    assert {:ok, :queued} = enqueue(c.b.service.store, activity, 1000)
    assert :ok = Store.call(c.b.service.store, {:project, c.id, metadata(), 1000})
    service = strict(c.b).service

    assert [%{stale: false, freshness_source: "projection"}] =
             FederationService.search(service, "", 1001)

    assert [%{stale: true}] = FederationService.search(service, "", 5000)
    assert :ok = Store.call(service.store, {:refresh, metadata()["id"], metadata(), 5000})

    assert [%{stale: false, freshness_source: "projection", verified_at: 5000}] =
             FederationService.search(service, "", 5001)
  end

  defp sign(config, m) do
    m = Map.delete(m, "signature")

    signature =
      :crypto.sign(:eddsa, :none, GossipSync.canonical(m), [config.seed, :ed25519])
      |> Base.encode64()

    Jason.encode!(Map.put(m, "signature", signature))
  end

  test "explicit renewal refreshes a stale exact projection without a new business revision", c do
    project(c)
    before = Store.call(c.b.service.store, :snapshot)
    local_before = Store.call(c.a.service.store, :snapshot)

    assert [%{stale: true, freshness_source: "projection"}] =
             FederationService.search(c.b.service, "", 5000)

    assert {:ok, %{"sequence" => 1, "expires" => 5300}} = GossipLease.renew(c.a, c.id, 300, 5000)
    assert {:ok, :accepted} = GossipLease.receive_event(c.b, wire(c.a, 5000), 5000)

    assert [
             %{
               stale: false,
               freshness_source: "publisher_lease",
               freshness_expires_at: 5300,
               verified_at: 1000
             }
           ] = FederationService.search(c.b.service, "", 5001)

    assert [%{stale: true, freshness_expires_at: 5300}] =
             FederationService.search(c.b.service, "", 5300)

    after_renewal = Store.call(c.b.service.store, :snapshot)
    assert after_renewal.remote == before.remote
    assert after_renewal.gossip_inbox == before.gossip_inbox
    assert after_renewal.events == %{} and after_renewal.local == %{}
    local_after = Store.call(c.a.service.store, :snapshot)
    assert local_after.events == local_before.events
    assert local_after.local == local_before.local
    assert local_after.publications == local_before.publications
  end

  test "absolute expiry and durable sequence refuse replays of a longer superseded lease", c do
    project(c)
    {:ok, _} = GossipLease.renew(c.a, c.id, 3600, 1000)
    old = wire(c.a, 1000)
    assert {:ok, :accepted} = GossipLease.receive_event(c.b, old, 1000)
    {:ok, _} = GossipLease.renew(c.a, c.id, 60, 1001)
    fresh = wire(c.a, 1001)
    assert {:ok, :accepted} = GossipLease.receive_event(c.b, fresh, 1001)
    assert {:error, :stale_lease} = GossipLease.receive_event(c.b, old, 1002)
    assert {:ok, :duplicate} = GossipLease.receive_event(c.b, wire(c.a, 1002), 1002)
    # Expiry overrides the original first-receipt grace once a lease is known.
    assert [%{stale: true, freshness_expires_at: 1061}] =
             FederationService.search(c.b.service, "", 1061)

    GenServer.stop(c.a.service.store)
    GenServer.stop(c.b.service.store)
    {:ok, a} = Store.start_link(directory: c.dir <> "/a")
    {:ok, b} = Store.start_link(directory: c.dir <> "/b")

    on_exit(fn ->
      stop_store(a)
      stop_store(b)
    end)

    ac = %{c.a | service: %{c.a.service | store: a}}
    bc = %{c.b | service: %{c.b.service | store: b}}
    assert {:error, :stale_lease} = GossipLease.receive_event(bc, old, 1003)
    assert {:ok, %{"sequence" => 3}} = GossipLease.renew(ac, c.id, 60, 1003)
    assert {:ok, :accepted} = GossipLease.receive_event(bc, wire(ac, 1003), 1003)
    assert map_size(Store.call(a, :snapshot).lease_local) == 1
    assert map_size(Store.call(b, :snapshot).lease_remote) == 1
  end

  test "signature, actor, scope, exact content, time and sequence tampering refuse", c do
    project(c)
    {:ok, _} = GossipLease.renew(c.a, c.id, 300, 1000)
    raw = wire(c.a, 1000)
    m = Jason.decode!(raw)

    for {field, value} <- [
          {"hash", String.duplicate("b", 64)},
          {"listing_id", "https://other.example/listings/x"},
          {"activity_id", c.id <> "-other"},
          {"actor", @beta},
          {"publisher", c.b.publisher},
          {"epoch", 2},
          {"issued", 1031},
          {"expires", 1000},
          {"expires", 4601},
          {"sequence", 0},
          {"command", "reserve"}
        ] do
      assert {:error, :lease_refused} =
               GossipLease.receive_event(c.b, sign(c.a, Map.put(m, field, value)), 1000)
    end

    assert {:error, :lease_refused} =
             GossipLease.receive_event(
               c.b,
               Jason.encode!(Map.put(m, "signature", Base.encode64(<<0::512>>))),
               1000
             )

    assert {:ok, :accepted} = GossipLease.receive_event(c.b, raw, 1000)

    assert {:error, :lease_conflict} =
             GossipLease.receive_event(c.b, sign(c.a, Map.put(m, "expires", 1200)), 1001)

    assert {:error, :lease_refused} = GossipLease.receive_event(c.b, raw, 1300)
  end

  test "lease-before-projection refuses and can be repaired after the exact advertisement arrives",
       c do
    {:ok, _} = GossipLease.renew(c.a, c.id, 300, 1000)
    raw = wire(c.a, 1000)
    assert {:error, :lease_refused} = GossipLease.receive_event(c.b, raw, 1000)
    assert Store.call(c.b.service.store, :snapshot).lease_remote == %{}
    project(c, 1001)
    assert {:ok, :accepted} = GossipLease.receive_event(c.b, raw, 1001)
  end

  test "updates and terminal withdrawals cannot inherit or be resurrected by a lease", c do
    project(c)
    {:ok, _} = GossipLease.renew(c.a, c.id, 3600, 1000)
    raw = wire(c.a, 1000)
    assert {:ok, :accepted} = GossipLease.receive_event(c.b, raw, 1000)

    assert {:ok, :published} =
             FederationService.publish(c.a.service, "source-1", metadata(@alpha, 1), :update)

    project(c, 1001)

    assert [%{freshness_source: "projection", metadata: %{"revision" => 1}}] =
             FederationService.search(c.b.service, "", 1002)

    assert {:error, :lease_refused} = GossipLease.receive_event(c.b, raw, 1002)
    assert GossipLease.frames(c.a, 1002, MapSet.new()) == []
    assert {:error, :lease_refused} = GossipLease.renew(c.a, c.id, 60, 1002)
    id = Store.call(c.a.service.store, :snapshot).local[metadata()["id"]].activity_id
    assert {:ok, %{"sequence" => 2}} = GossipLease.renew(c.a, id, 300, 1002)
    assert {:ok, :accepted} = GossipLease.receive_event(c.b, wire(c.a, 1002), 1002)

    assert {:ok, :published} =
             FederationService.withdraw(c.a.service, "withdraw", metadata()["id"])

    project(c, 1003)
    assert FederationService.search(c.b.service, "", 1004) == []
    assert {:error, :lease_refused} = GossipLease.receive_event(c.b, raw, 1004)
    assert {:error, :lease_refused} = GossipLease.renew(c.a, id, 300, 1004)
    assert GossipLease.frames(c.a, 1004, MapSet.new()) == []
  end

  test "current pins, moderation and transport provenance govern acceptance and visibility", c do
    project(c)
    {:ok, _} = GossipLease.renew(c.a, c.id, 60, 5000)
    raw = wire(c.a, 5000)
    revoked = %{c.b | publisher_keys: Map.delete(c.b.publisher_keys, @alpha)}
    assert {:error, :lease_refused} = GossipLease.receive_event(revoked, raw, 5000)
    Store.call(c.b.service.store, {:block, metadata()["id"], true})
    assert {:error, :lease_refused} = GossipLease.receive_event(c.b, raw, 5000)
    Store.call(c.b.service.store, {:block, metadata()["id"], false})
    assert {:ok, :accepted} = GossipLease.receive_event(c.b, raw, 5000)

    hidden = %{
      c.b.service
      | gossip_policy: %{
          c.b.service.gossip_policy
          | publisher_keys: Map.delete(c.b.publisher_keys, @alpha)
        }
    }

    assert FederationService.search(hidden, "", 5001) == []
    {:ok, http_store} = Store.start_link(directory: c.dir <> "/http")
    on_exit(fn -> stop_store(http_store) end)
    activity = Store.call(c.a.service.store, :snapshot).publications[c.id]
    assert {:ok, :queued} = enqueue(http_store, activity, 1000)
    assert :ok = Store.call(http_store, {:project, c.id, metadata(), 1000})
    http_config = %{c.b | service: %{c.b.service | store: http_store}}
    assert {:error, :lease_refused} = GossipLease.receive_event(http_config, raw, 5000)

    assert [%{stale: true, freshness_source: "projection"}] =
             FederationService.search(http_config.service, "", 5001)
  end

  test "a stale local queue acknowledgment cannot mark a newer renewal sent", c do
    {:ok, _} = GossipLease.renew(c.a, c.id, 300, 1000)
    [{old_id, _}] = GossipLease.frames(c.a, 1000, MapSet.new())
    assert :ok = GossipLease.sent(c.a, old_id, 1000)
    assert GossipLease.frames(c.a, 1001, MapSet.new()) == []
    assert {:ok, %{"sequence" => 2}} = GossipLease.renew(c.a, c.id, 300, 1001)
    assert :ok = GossipLease.sent(c.a, old_id, 1002)
    assert [{new_id, _}] = GossipLease.frames(c.a, 1002, MapSet.new())
    refute old_id == new_id
    refute GossipLease.current?(c.a, old_id, 1002)
    assert GossipLease.current?(c.a, new_id, 1002)
    assert GossipLease.frames(c.a, 1301, MapSet.new()) == []
  end

  test "invalid TTL, backward clocks and missing publications refuse without changing source state",
       c do
    for ttl <- [0, -1, 3601, 1.5] do
      assert {:error, :lease_refused} = GossipLease.renew(c.a, c.id, ttl, 1000)
    end

    assert {:error, :lease_refused} = GossipLease.renew(c.a, "missing", 60, 1000)
    assert {:ok, _} = GossipLease.renew(c.a, c.id, 60, 1000)
    assert {:error, :lease_refused} = GossipLease.renew(c.a, c.id, 60, 999)
    assert {:error, :lease_refused} = GossipLease.renew(c.a, c.id, 60, -1)
    assert {:error, :lease_refused} = GossipLease.renew(c.a, c.id, 60, 9_007_199_254_740_991)
    assert map_size(Store.call(c.a.service.store, :snapshot).lease_local) == 1
  end

  test "unsupported attachment extensions stay on legacy freshness without crashing lease handling",
       c do
    {:ok, _} = GossipLease.renew(c.a, c.id, 300, 1000)
    old = wire(c.a, 1000) |> Jason.decode!()
    m = metadata(@alpha, 1)
    extended = activity(m, "extended", :update)
    [attachment] = extended["object"]["attachment"]
    extended = put_in(extended["object"]["attachment"], [Map.put(attachment, "weight", 1.5)])
    id = extended["id"]

    assert {:ok, :published} =
             Store.call(c.a.service.store, {:publish, "extended", extended, m, [], 1001})

    project(c, 1001)
    assert {:error, :lease_refused} = GossipLease.renew(c.a, id, 60, 1002)
    assert GossipLease.frames(c.a, 1002, MapSet.new()) == []

    forged =
      Map.merge(old, %{"activity_id" => id, "hash" => String.duplicate("b", 64), "sequence" => 2})

    assert {:error, :lease_refused} = GossipLease.receive_event(c.b, sign(c.a, forged), 1002)
    assert Process.alive?(c.b.service.store)
    assert [%{freshness_source: "projection"}] = FederationService.search(c.b.service, "", 1003)
  end

  test "a bounded future-issued lease is not fresh before its signed start", c do
    project(c)
    {:ok, _} = GossipLease.renew(c.a, c.id, 60, 1010)
    assert {:ok, :accepted} = GossipLease.receive_event(c.b, wire(c.a, 1010), 1000)

    assert [%{stale: true, freshness_expires_at: 1070}] =
             FederationService.search(c.b.service, "", 1005)

    assert [%{stale: false}] = FederationService.search(c.b.service, "", 1010)
  end
end
