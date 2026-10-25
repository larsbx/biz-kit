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
    Store.call(c.s, {:delivery, id, 0, true, 1001})
    assert Store.call(c.s, :snapshot).outbox[id].status == :held
    assert {:ok, %{settled: 1, resumed: 0}} = FederationService.reconcile(config, 1002)
    Store.call(c.s, {:delivery, id, 0, false, 1003})
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
      Store.call(c.s, {:delivery, id, 0, false, 1001})
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

  test "withdrawals reserve insertion priority before batch and capacity limits", c do
    for n <- 1..33 do
      m = metadata(@actor, 0, %{listing_id: "https://alpha.example/listings/a-live-#{n}"})
      FederationService.publish(c.config, "live-#{n}", m)
    end

    gone = metadata(@actor, 0, %{listing_id: "https://alpha.example/listings/zz-withdrawn"})
    FederationService.publish(c.config, "gone", gone)
    FederationService.withdraw(c.config, "gone-delete", gone["id"])
    original = Store.call(c.s, :snapshot)
    config = %{c.config | peers: [@peer]}
    assert {:ok, %{inserted: 32, more: true}} = FederationService.reconcile(config, 1000)
    queued = Store.call(c.s, :snapshot).outbox |> Map.values()
    assert Enum.count(queued, &(&1.activity["type"] == "Delete")) == 1
    assert Enum.count(queued, &(&1.activity["type"] == "Create")) == 31

    # Old completed receipts may leave only one slot. A live advertisement
    # must not consume that slot ahead of the retained terminal withdrawal.
    row = hd(queued) |> Map.put(:status, :delivered)
    nearly_full = %{original | outbox: Map.new(1..9999, fn n -> {n, row} end)}
    {changes, stats} = Delivery.plan(nearly_full, @actor, [@peer], 1001)
    assert [{:outbox, _, %{activity: %{"type" => "Delete", "object" => %{"id" => id}}}}] = changes
    assert id == gone["id"] and stats.capacity and stats.more
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

  test "explicit redelivery requeues current acknowledgments without changing source history",
       c do
    config = %{c.config | peers: [@peer]}
    m = metadata()
    FederationService.publish(config, "old", m)
    FederationService.publish(config, "current", metadata(@actor, 2), :update)
    gone = metadata(@actor, 0, %{listing_id: "https://alpha.example/listings/gone"})
    FederationService.publish(config, "gone", gone)
    FederationService.withdraw(config, "delete", gone["id"])
    FederationService.reconcile(config, 1000)
    before = Store.call(c.s, :snapshot)
    current = Enum.filter(before.outbox, fn {_, row} -> row.status == :pending end)
    for {id, _} <- current, do: Store.call(c.s, {:delivery, id, 0, true, 1001})

    assert {:ok, 1} = FederationService.redeliver(config, @peer, 1002)

    assert {:ok, %{requeued: 2, inserted: 0, more: false}} =
             FederationService.reconcile(config, 1003)

    snapshot = Store.call(c.s, :snapshot)
    assert snapshot.local == before.local and snapshot.events == before.events
    assert snapshot.publications == before.publications
    assert map_size(snapshot.outbox) == map_size(before.outbox)
    assert Enum.count(snapshot.outbox, fn {_, row} -> row.status == :superseded end) == 2

    for {id, _} <- current do
      row = snapshot.outbox[id]
      assert row.generation == 1 and row.status == :pending and row.next_at == 1003
      assert row.acknowledged_at == 1001 and row.acknowledged_generation == 0
      assert Store.call(c.s, {:delivery, id, 1, true, 1004}) == :ok
    end

    assert {:ok, %{requeued: 0, more: false}} = FederationService.reconcile(config, 1005)

    assert Enum.all?(current, fn {id, _} ->
             row = Store.call(c.s, :snapshot).outbox[id]

             row.status == :delivered and row.acknowledged_at == 1001 and
               row.last_acknowledged_at == 1004 and row.acknowledged_generation == 1
           end)
  end

  test "a new redelivery generation rejects old in-flight success and failure before reconciliation",
       c do
    config = %{c.config | peers: [@peer]}
    FederationService.publish(config, "first", metadata())
    [id] = Map.keys(Store.call(c.s, :snapshot).outbox)
    original = Store.call(c.s, :snapshot).outbox[id]
    assert {:ok, 1} = FederationService.redeliver(config, @peer, 1000)
    refute Delivery.ready?(Store.call(c.s, :snapshot), @actor, [@peer], original)

    for success <- [true, false] do
      assert {:error, :stale_delivery} = Store.call(c.s, {:delivery, id, 0, success, 1001})
    end

    assert Store.call(c.s, :snapshot).outbox[id] == original
    assert {:ok, %{requeued: 1}} = FederationService.reconcile(config, 1002)
    assert :ok = Store.call(c.s, {:delivery, id, 1, true, 1003})
    assert {:ok, 2} = FederationService.redeliver(config, @peer, 1004)
    assert {:error, :stale_delivery} = Store.call(c.s, {:delivery, id, 1, true, 1005})
    assert {:ok, %{requeued: 1}} = FederationService.reconcile(config, 1006)
    row = Store.call(c.s, :snapshot).outbox[id]
    assert row.status == :pending and row.generation == 2 and row.acknowledged_generation == 1
    assert {:error, :stale_delivery} = Store.call(c.s, {:delivery, id, 1, false, 1007})
    assert Store.call(c.s, :snapshot).outbox[id] == row
  end

  test "redelivery requests and a partially reconciled batch survive restart; withdrawals go first",
       c do
    config = %{c.config | peers: [@peer]}

    for n <- 1..33 do
      m = metadata(@actor, 0, %{listing_id: "https://alpha.example/listings/a-live-#{n}"})
      FederationService.publish(config, "event-#{n}", m)
    end

    gone = metadata(@actor, 0, %{listing_id: "https://alpha.example/listings/zz-gone"})
    FederationService.withdraw(config, "delete", gone["id"])

    for {id, _} <- Store.call(c.s, :snapshot).outbox do
      Store.call(c.s, {:delivery, id, 0, true, 1000})
    end

    assert {:ok, 1} = FederationService.redeliver(config, @peer, 1001)
    GenServer.stop(c.s)
    {:ok, s} = Store.start_link(directory: c.dir)
    config = %{config | store: s}
    assert {:ok, %{requeued: 32, more: true}} = FederationService.reconcile(config, 1002)
    snap = Store.call(s, :snapshot)
    assert snap.redeliveries[@peer].generation == 1

    assert Enum.any?(snap.outbox, fn {_, row} ->
             row.activity["type"] == "Delete" and row.status == :pending and row.generation == 1
           end)

    GenServer.stop(s)
    {:ok, s} = Store.start_link(directory: c.dir)
    config = %{config | store: s}
    assert {:ok, %{requeued: 2, more: false}} = FederationService.reconcile(config, 1003)
    assert {:ok, %{requeued: 0, more: false}} = FederationService.reconcile(config, 1004)
    assert Enum.all?(Store.call(s, :snapshot).outbox, fn {_, r} -> r.generation == 1 end)
    GenServer.stop(s)
  end

  test "redelivery keeps moderation and peer policy; historical acknowledgments cannot settle new work",
       c do
    config = %{c.config | peers: [@peer]}
    m = metadata()
    FederationService.publish(config, "first", m)
    [id] = Map.keys(Store.call(c.s, :snapshot).outbox)
    Store.call(c.s, {:delivery, id, 0, true, 1000})
    before = Store.call(c.s, :snapshot)
    assert {:error, :peer_refused} = FederationService.redeliver(c.config, @peer, 1001)
    assert {:error, :peer_refused} = FederationService.redeliver(config, @actor, 1001)

    assert {:error, :peer_refused} =
             FederationService.redeliver(config, "https://other.example/actors/shop", 1001)

    assert Store.call(c.s, :snapshot) == before
    Store.call(c.s, {:block, "beta.example", true})
    assert {:error, :peer_refused} = FederationService.redeliver(config, @peer, 1002)
    Store.call(c.s, {:block, "beta.example", false})
    assert {:ok, 1} = FederationService.redeliver(config, @peer, 1003)
    Store.call(c.s, {:block, m["id"], true})
    assert {:ok, %{held: 1, requeued: 1}} = FederationService.reconcile(config, 1004)
    assert Store.call(c.s, :snapshot).outbox[id].status == :held
    Store.call(c.s, {:block, m["id"], false})
    assert {:ok, %{resumed: 1, settled: 0}} = FederationService.reconcile(config, 1005)
    assert Store.call(c.s, :snapshot).outbox[id].status == :pending
    assert :ok = Store.call(c.s, {:delivery, id, 1, true, 1006})
  end

  test "redelivery does not forward foreign projections or reset a different peer's receipts",
       c do
    other = "https://gamma.example/actors/shop"
    config = %{c.config | peers: [@peer, other]}
    FederationService.publish(config, "first", metadata())
    m = metadata(@peer)
    a = activity(m)
    enqueue(c.s, a)
    Store.call(c.s, {:project, a["id"], m, 1000})

    for {id, _} <- Store.call(c.s, :snapshot).outbox do
      Store.call(c.s, {:delivery, id, 0, true, 1001})
    end

    before = Store.call(c.s, :snapshot)
    assert {:ok, 1} = FederationService.redeliver(config, @peer, 1002)
    assert {:ok, %{requeued: 1, inserted: 0}} = FederationService.reconcile(config, 1003)
    after_repair = Store.call(c.s, :snapshot)
    assert after_repair.remote == before.remote and map_size(after_repair.outbox) == 2

    for {id, row} <- before.outbox, row.destination == other do
      assert after_repair.outbox[id] == row
    end
  end

  test "journals written before delivery generations retain legacy acknowledgments", c do
    config = %{c.config | peers: [@peer]}
    FederationService.publish(config, "legacy", metadata())
    [{id, row}] = Map.to_list(Store.call(c.s, :snapshot).outbox)

    legacy =
      row |> Map.delete(:generation) |> Map.merge(%{status: :delivered, acknowledged_at: 999})

    log = :sys.get_state(c.s).log
    :ok = :disk_log.log(log, {:transaction, [{:outbox, id, legacy}]})
    :ok = :disk_log.sync(log)
    GenServer.stop(c.s)
    {:ok, s} = Store.start_link(directory: c.dir)
    config = %{config | store: s}
    assert {:ok, %{requeued: 0}} = FederationService.reconcile(config, 1000)
    assert Store.call(s, :snapshot).outbox[id] == legacy
    assert {:ok, 1} = FederationService.redeliver(config, @peer, 1001)
    assert {:ok, %{requeued: 1}} = FederationService.reconcile(config, 1002)
    row = Store.call(s, :snapshot).outbox[id]
    assert row.generation == 1 and row.status == :pending and row.acknowledged_at == 999
    GenServer.stop(s)
  end
end
