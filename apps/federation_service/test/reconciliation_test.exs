defmodule FederationService.ReconciliationTest do
  use ExUnit.Case, async: true
  alias FederationService.{Store, Delivery, Inbox}
  import FederationService.TestHelpers
  @actor "https://alpha.example/actors/shop"
  @peer "https://beta.example/actors/shop"
  setup do
    dir = temp()
    {:ok, store} = Store.start_link(directory: dir)
    config = FederationService.config!(actor: @actor, store: store, private_key: key())

    on_exit(fn ->
      stop_store(store)
      File.rm_rf!(dir)
    end)

    %{s: store, dir: dir, config: config}
  end

  test "new peers receive only current snapshots and tombstones with stable IDs", c do
    m0 = metadata()
    m2 = metadata(@actor, 2)
    gone = metadata(@actor, 0, %{listing_id: "https://alpha.example/listings/gone"})
    FederationService.publish(c.config, "first", m0)
    FederationService.publish(c.config, "current", m2, :update)
    FederationService.publish(c.config, "gone", gone)
    FederationService.withdraw(c.config, "delete", gone["id"])
    before = Store.call(c.s, :snapshot)
    config = %{c.config | peers: [@peer]}
    assert {:ok, %{inserted: 2, more: false}} = FederationService.reconcile(config, 1000)
    snapshot = Store.call(c.s, :snapshot)
    assert snapshot.events == before.events and snapshot.local == before.local
    assert snapshot.publications == before.publications

    assert Enum.sort(Enum.map(snapshot.outbox, fn {_, r} -> r.activity["type"] end)) == [
             "Delete",
             "Update"
           ]

    for {{id, peer}, r} <- snapshot.outbox do
      assert id == snapshot.local[r.activity["object"]["id"]].activity_id
      assert peer == @peer and r.attempts == 0
    end

    assert {:ok, %{inserted: 0, more: false}} = FederationService.reconcile(config, 1001)
    assert {:ok, :duplicate} = FederationService.publish(config, "first", m0)
  end

  test "remote projections are never forwarded as local publications", c do
    m = metadata(@peer)
    a = activity(m)
    enqueue(c.s, a)
    Store.call(c.s, {:project, a["id"], m, 1000})
    assert {:ok, %{inserted: 0}} = FederationService.reconcile(%{c.config | peers: [@peer]}, 1001)
    data = Store.call(c.s, :snapshot)
    assert map_size(data.remote) == 1 and data.outbox == %{} and data.events == %{}
  end

  test "pending rows pause on peer removal or moderation and resume without retry churn", c do
    config = %{c.config | peers: [@peer]}
    m = metadata()
    FederationService.publish(config, "first", m)
    [id] = Map.keys(Store.call(c.s, :snapshot).outbox)
    assert {:ok, %{held: 1}} = FederationService.reconcile(c.config, 1000)
    assert Store.call(c.s, :snapshot).outbox[id].hold_reason == :peer_removed
    assert {:ok, %{held: 0}} = FederationService.reconcile(c.config, 1001)
    assert Store.call(c.s, :snapshot).outbox[id].attempts == 0
    assert {:ok, %{resumed: 1}} = FederationService.reconcile(config, 1002)
    assert Store.call(c.s, :snapshot).outbox[id].next_at == 1002
    Store.call(c.s, {:block, m["id"], true})
    assert {:ok, %{held: 1}} = FederationService.reconcile(config, 1003)
    assert Store.call(c.s, :snapshot).outbox[id].hold_reason == :listing_blocked
    Store.call(c.s, {:block, m["id"], false})
    assert {:ok, %{resumed: 1}} = FederationService.reconcile(config, 1004)
    Store.call(c.s, {:block, @peer, true})
    assert {:ok, %{held: 1}} = FederationService.reconcile(config, 1005)
    assert Store.call(c.s, :snapshot).outbox[id].hold_reason == :peer_blocked
  end

  test "an in-flight acknowledgment survives a policy hold and later failed duplicates", c do
    config = %{c.config | peers: [@peer]}
    FederationService.publish(config, "first", metadata())
    [id] = Map.keys(Store.call(c.s, :snapshot).outbox)
    FederationService.reconcile(c.config, 1000)
    Store.call(c.s, {:delivery, id, true, 1001})
    assert Store.call(c.s, :snapshot).outbox[id].status == :held
    assert {:ok, %{settled: 1, resumed: 0}} = FederationService.reconcile(config, 1002)
    Store.call(c.s, {:delivery, id, false, 1003})
    row = Store.call(c.s, :snapshot).outbox[id]
    assert row.status == :delivered and row.acknowledged_at == 1001
    assert row.last_delivery == %{at: 1003, acknowledged: false}
    GenServer.stop(c.s)
    {:ok, s} = Store.start_link(directory: c.dir)
    assert Store.call(s, :snapshot).outbox[id].acknowledged_at == 1001
    GenServer.stop(s)
  end

  test "a changed local actor cannot inherit delivery authority for old publications", c do
    config = %{c.config | peers: [@peer]}
    FederationService.publish(config, "first", metadata())

    assert {:ok, %{held: 1, inserted: 0}} =
             FederationService.reconcile(
               %{config | actor: "https://changed.example/actors/shop"},
               1000
             )

    [row] = Store.call(c.s, :snapshot).outbox |> Map.values()
    assert row.hold_reason == :actor_mismatch and row.attempts == 0
  end

  test "newer revisions and withdrawal retire obsolete retries durably; late receipts cannot revive them",
       c do
    config = %{c.config | peers: [@peer]}
    m = metadata()
    FederationService.publish(config, "first", m)
    FederationService.publish(config, "second", metadata(@actor, 1), :update)
    FederationService.withdraw(config, "delete", m["id"])
    assert {:ok, %{superseded: 2}} = FederationService.reconcile(config, 1000)
    snap = Store.call(c.s, :snapshot)

    for {id, row} <- snap.outbox, row.status == :superseded do
      Store.call(c.s, {:delivery, id, false, 1001})
      assert Store.call(c.s, :snapshot).outbox[id].status == :superseded
    end

    GenServer.stop(c.s)
    {:ok, s} = Store.start_link(directory: c.dir)

    assert Enum.count(Store.call(s, :snapshot).outbox, fn {_, r} -> r.status == :superseded end) ==
             2

    GenServer.stop(s)
  end

  test "reconciliation is bounded, repeatable and never silently drops receipts at capacity", c do
    for n <- 1..40 do
      m = metadata(@actor, 0, %{listing_id: "https://alpha.example/listings/part-#{n}"})
      FederationService.publish(c.config, "event-#{n}", m)
    end

    config = %{c.config | peers: [@peer]}

    assert {:ok, %{inserted: 32, more: true, capacity: false}} =
             FederationService.reconcile(config, 1000)

    assert {:ok, %{inserted: 8, more: false}} = FederationService.reconcile(config, 1001)
    assert {:ok, %{inserted: 0, more: false}} = FederationService.reconcile(config, 1002)
    data = Store.call(c.s, :snapshot)
    row = data.outbox |> Map.values() |> hd() |> Map.put(:status, :delivered)
    full = %{data | outbox: Map.new(1..10_000, fn n -> {n, row} end)}
    {changes, stats} = Delivery.plan(full, @actor, [@peer], 1003)
    assert changes == [] and stats.capacity and stats.more
    assert map_size(full.outbox) == 10_000
  end

  test "terminal remote tombstones retire delayed inbox work without contacting unavailable origins",
       c do
    m = metadata()

    {:ok, del} =
      FederationCore.Marketplace.withdraw(@actor, m["id"], @actor <> "/activities/delete")

    enqueue(c.s, del)
    Store.call(c.s, {:project, del["id"], nil, 1000})
    old = activity(m, "late")
    enqueue(c.s, old)
    # No network test routes are configured. The terminal local evidence alone
    # must reject this work instead of retrying a now-unavailable metadata URL.
    Inbox.drain(%{c.config | peers: [@actor]}, 1001)
    assert Store.call(c.s, :snapshot).inbox[old["id"]].status == {:rejected, :withdrawn}
  end
end
