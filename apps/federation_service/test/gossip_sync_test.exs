defmodule FederationService.GossipSyncTest do
  use ExUnit.Case, async: true
  alias FederationService.{Gossip, GossipSync, Store}
  import FederationService.TestHelpers
  @alpha "https://alpha.example/actors/shop"
  @beta "https://beta.example/actors/shop"

  setup do
    dir = temp()
    {:ok, a} = Store.start_link(directory: dir <> "/a")
    {:ok, b} = Store.start_link(directory: dir <> "/b")
    sa = :crypto.strong_rand_bytes(32)
    sb = :crypto.strong_rand_bytes(32)

    public = fn seed ->
      {key, _} = :crypto.generate_key(:eddsa, :ed25519, seed)
      Base.encode16(key, case: :lower)
    end

    keys = %{@alpha => public.(sa), @beta => public.(sb)}
    scope = %{"halaqa_id" => "market", "charter_hash" => String.duplicate("a", 64), "epoch" => 1}

    make = fn actor, store, seed ->
      Gossip.config!(FederationService.config!(actor: actor, private_key: nil, store: store),
        scope: scope,
        seed: seed,
        publisher_keys: keys
      )
    end

    on_exit(fn ->
      stop_store(a)
      stop_store(b)
      File.rm_rf!(dir)
    end)

    %{a: make.(@alpha, a, sa), b: make.(@beta, b, sb), dir: dir}
  end

  defp publish(c, revision \\ 0) do
    assert {:ok, :published} =
             FederationService.publish(
               c.service,
               "event-#{revision}",
               metadata(@alpha, revision),
               if(revision == 0, do: :create, else: :update)
             )

    Store.call(c.service.store, :snapshot).local[metadata()["id"]].activity_id
  end

  defp frame(c, now \\ 1000) do
    [{_, wire} | _] = GossipSync.frames(c, now, MapSet.new())
    wire
  end

  defp project(a, b, now \\ 1001) do
    for {_, wire} <- Gossip.frames(a, now) do
      assert {:ok, :queued} = Gossip.receive_event(b, wire, now)
    end

    Gossip.drain(b, now)
  end

  defp signed(c, m) do
    m = Map.delete(m, "signature")

    sig =
      :crypto.sign(:eddsa, :none, GossipSync.canonical(m), [c.seed, :ed25519]) |> Base.encode64()

    Jason.encode!(Map.put(m, "signature", sig))
  end

  test "completion requires all projections, survives restart, and stores signed receiver evidence",
       c do
    id = publish(c.a)
    assert {:ok, round} = GossipSync.start_round(c.a, @beta, [id], 1000)
    offer = frame(c.a)
    assert :ok = GossipSync.receive_event(c.b, offer, 1000)
    GossipSync.drain(c.b, 1000)
    assert GossipSync.frames(c.b, 1000, MapSet.new()) == []
    assert {:ok, %{state: :pending}} = GossipSync.status(c.a, round, 1000)
    project(c.a, c.b)
    GossipSync.drain(c.b, 1002)
    receipt = frame(c.b, 1002)
    before = Store.call(c.b.service.store, :snapshot).remote
    assert :ok = GossipSync.receive_event(c.a, receipt, 1002)

    assert {:ok, %{state: :complete, current: true, receipt: evidence}} =
             GossipSync.status(c.a, round, 1002)

    assert evidence.signed_message["signature"] != nil
    assert evidence.message["from"] == @beta
    assert :ok = GossipSync.receive_event(c.a, frame(c.b, 1003), 1003)
    assert Store.call(c.b.service.store, :snapshot).remote == before
    for config <- [c.a, c.b], do: GenServer.stop(config.service.store)
    {:ok, a} = Store.start_link(directory: c.dir <> "/a")
    {:ok, b} = Store.start_link(directory: c.dir <> "/b")

    on_exit(fn ->
      stop_store(a)
      stop_store(b)
    end)

    a_config = %{c.a | service: %{c.a.service | store: a}}
    b_config = %{c.b | service: %{c.b.service | store: b}}

    assert {:ok, %{state: :complete, receipt: ^evidence}} =
             GossipSync.status(a_config, round, 1004)

    assert Jason.decode!(frame(b_config, 1004))["journal"] == evidence.message["journal"]
    assert Store.call(a, :snapshot).events |> map_size() == 1
    assert Store.call(b, :snapshot).events == %{}
  end

  test "local queue acceptance cannot complete a round; unknown and tampered receipts refuse",
       c do
    id = publish(c.a)
    {:ok, round} = GossipSync.start_round(c.a, @beta, [id], 1000)
    [{key, _}] = GossipSync.frames(c.a, 1000, MapSet.new())
    assert :ok = GossipSync.sent(c.a, key, 1000)
    assert {:ok, %{state: :pending}} = GossipSync.status(c.a, round, 1001)
    assert GossipSync.frames(c.a, 1001, MapSet.new()) == []
    assert :ok = GossipSync.receive_event(c.b, frame(c.a, 1031), 1031)
    project(c.a, c.b, 1032)
    GossipSync.drain(c.b, 1032)
    receipt = Jason.decode!(frame(c.b, 1032))

    for {field, value} <- [
          {"batch", String.duplicate("b", 64)},
          {"round", String.duplicate("b", 32)},
          {"to", @beta},
          {"epoch", 2},
          {"publisher", c.a.publisher},
          {"journal", "bad"},
          {"expires", 999}
        ] do
      bad = Map.put(receipt, field, value)
      assert {:error, :catchup_refused} = GossipSync.receive_event(c.a, signed(c.b, bad), 1033)
    end

    assert {:error, :catchup_refused} =
             GossipSync.receive_event(
               c.a,
               Jason.encode!(Map.put(receipt, "signature", Base.encode64(<<0::512>>))),
               1033
             )

    assert {:ok, %{state: :pending}} = GossipSync.status(c.a, round, 1033)
  end

  test "scope changes, revocation, moderation, expired and superseded batches do not complete",
       c do
    id = publish(c.a)
    {:ok, round} = GossipSync.start_round(c.a, @beta, [id], 1000)
    offer = frame(c.a)
    assert :ok = GossipSync.receive_event(c.b, offer, 1000)
    project(c.a, c.b)
    revoked = %{c.b | publisher_keys: Map.delete(c.b.publisher_keys, @alpha)}
    GossipSync.drain(revoked, 1002)
    assert GossipSync.frames(revoked, 1002, MapSet.new()) == []
    Store.call(c.b.service.store, {:block, metadata()["id"], true})
    GossipSync.drain(c.b, 1003)
    assert GossipSync.frames(c.b, 1003, MapSet.new()) == []
    Store.call(c.b.service.store, {:block, metadata()["id"], false})
    GossipSync.drain(c.b, 1004)
    receipt = frame(c.b, 1004)

    assert {:error, :catchup_refused} =
             GossipSync.receive_event(
               %{c.a | scope: Map.put(c.a.scope, "epoch", 2)},
               receipt,
               1004
             )

    assert {:error, :catchup_refused} =
             GossipSync.receive_event(
               %{c.a | publisher_keys: Map.delete(c.a.publisher_keys, @beta)},
               receipt,
               1004
             )

    publish(c.a, 1)
    assert {:ok, %{state: :superseded}} = GossipSync.status(c.a, round, 1005)
    assert :ok = GossipSync.receive_event(c.a, receipt, 1005)
    assert {:ok, %{state: :complete, current: false}} = GossipSync.status(c.a, round, 1005)
    assert {:error, :catchup_refused} = GossipSync.receive_event(c.a, receipt, 4600)
  end

  test "rounds reject oversized, duplicate, foreign and conflicting batch descriptions", c do
    id = publish(c.a)

    for ids <- [[], [id, id], List.duplicate(id, 17), ["https://foreign.example/activity"]] do
      assert {:error, :catchup_refused} = GossipSync.start_round(c.a, @beta, ids, 1000)
    end

    {:ok, _} = GossipSync.start_round(c.a, @beta, [id], 1000)
    offer = frame(c.a) |> Jason.decode!()
    assert :ok = GossipSync.receive_event(c.b, Jason.encode!(offer), 1000)

    assert {:error, :catchup_refused} =
             GossipSync.receive_event(
               c.b,
               signed(c.a, Map.put(offer, "command", "reserve")),
               1001
             )

    wrong = put_in(offer["entries"], [%{"id" => id, "hash" => String.duplicate("b", 64)}])

    batch =
      Map.take(
        wrong,
        ~w(halaqa_id charter_hash epoch schema from to publisher round entries expires)
      )

    hash = :crypto.hash(:sha256, GossipSync.canonical(batch)) |> Base.encode16(case: :lower)

    assert {:error, :catchup_conflict} =
             GossipSync.receive_event(c.b, signed(c.a, Map.put(wrong, "batch", hash)), 1002)

    assert :not_sync = GossipSync.receive_event(c.b, String.duplicate("x", 65_537), 1003)
  end

  test "rejected or conflicting advertisements and wrong hashes cannot be acknowledged", c do
    id = publish(c.a)
    {:ok, round} = GossipSync.start_round(c.a, @beta, [id], 1000)
    assert :ok = GossipSync.receive_event(c.b, frame(c.a), 1000)
    project(c.a, c.b)
    Store.call(c.b.service.store, {:gossip_reject, id, :test_refusal})
    GossipSync.drain(c.b, 1002)
    assert GossipSync.frames(c.b, 1002, MapSet.new()) == []
    assert {:ok, %{state: :pending}} = GossipSync.status(c.a, round, 1002)
  end

  test "a full 16-item batch stays pending until its final durable projection", c do
    ids =
      for n <- 1..16 do
        m = metadata(@alpha, 0, %{listing_id: "https://alpha.example/listings/item-#{n}"})
        assert {:ok, :published} = FederationService.publish(c.a.service, "item-#{n}", m)
        Store.call(c.a.service.store, :snapshot).local[m["id"]].activity_id
      end

    assert {:ok, round} = GossipSync.start_round(c.a, @beta, ids, 1000)
    assert :ok = GossipSync.receive_event(c.b, frame(c.a), 1000)
    [last | first] = Gossip.frames(c.a, 1001)
    for {_, wire} <- first, do: assert({:ok, :queued} = Gossip.receive_event(c.b, wire, 1001))
    Gossip.drain(c.b, 1002)
    GossipSync.drain(c.b, 1002)
    assert GossipSync.frames(c.b, 1002, MapSet.new()) == []
    assert {:ok, %{state: :pending}} = GossipSync.status(c.a, round, 1002)
    assert {:ok, :queued} = Gossip.receive_event(c.b, elem(last, 1), 1003)
    Gossip.drain(c.b, 1003)
    GossipSync.drain(c.b, 1004)
    assert :ok = GossipSync.receive_event(c.a, frame(c.b, 1004), 1004)
    assert {:ok, %{state: :complete}} = GossipSync.status(c.a, round, 1004)
  end

  test "outgoing capacity fails closed and expired batches produce no traffic", c do
    id = publish(c.a)

    rounds =
      for _ <- 1..128 do
        assert {:ok, round} = GossipSync.start_round(c.a, @beta, [id], 1000)
        round
      end

    assert {:error, :capacity} = GossipSync.start_round(c.a, @beta, [id], 1000)
    assert length(GossipSync.frames(c.a, 1001, MapSet.new())) == 4
    assert GossipSync.frames(c.a, 4600, MapSet.new()) == []
    assert {:ok, %{state: :expired}} = GossipSync.status(c.a, hd(rounds), 4600)
    assert map_size(Store.call(c.a.service.store, :snapshot).sync_outgoing) == 128
  end

  test "crash after projection and before receipt resumes the pending round", c do
    id = publish(c.a)
    {:ok, round} = GossipSync.start_round(c.a, @beta, [id], 1000)
    assert :ok = GossipSync.receive_event(c.b, frame(c.a), 1000)
    project(c.a, c.b)
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
    assert {:ok, %{state: :pending}} = GossipSync.status(ac, round, 1002)
    GossipSync.drain(bc, 1002)
    assert :ok = GossipSync.receive_event(ac, frame(bc, 1002), 1002)
    assert {:ok, %{state: :complete}} = GossipSync.status(ac, round, 1002)
    refute Gossip.frames(ac, 1003) == []
  end

  test "unresolved offers cannot starve a later ready batch", c do
    id = publish(c.a)
    for _ <- 1..17, do: assert({:ok, _} = GossipSync.start_round(c.a, @beta, [id], 1000))
    offers = Store.call(c.a.service.store, :snapshot).sync_outgoing |> Enum.sort()
    {_, ready} = List.last(offers)

    for {key, row} <- offers do
      m = row.message |> Map.put("announcement", String.duplicate("a", 32))

      m =
        if key == elem(List.last(offers), 0),
          do: m,
          else: put_in(m["entries"], [%{"id" => id, "hash" => String.duplicate("b", 64)}])

      batch =
        Map.take(
          m,
          ~w(halaqa_id charter_hash epoch schema from to publisher round entries expires)
        )

      hash = :crypto.hash(:sha256, GossipSync.canonical(batch)) |> Base.encode16(case: :lower)
      assert :ok = GossipSync.receive_event(c.b, signed(c.a, Map.put(m, "batch", hash)), 1000)
    end

    project(c.a, c.b)
    GossipSync.drain(c.b, 1002)
    assert :ok = GossipSync.receive_event(c.a, frame(c.b, 1002), 1002)
    assert {:ok, %{state: :complete}} = GossipSync.status(c.a, ready.message["round"], 1002)

    assert Enum.count(Store.call(c.b.service.store, :snapshot).sync_incoming, fn {_, row} ->
             row.status == :complete
           end) == 1
  end

  test "canonical content hashes are insensitive to object order but bind exact values" do
    assert GossipSync.canonical(%{"z" => [1, true, nil], "a" => "x"}) ==
             ~s({"a":"x","z":[1,true,null]})

    a = %{"actor" => @alpha, "id" => "x"}

    assert GossipSync.content_hash(a, %{"x" => 1, "y" => 2}) ==
             GossipSync.content_hash(a, Map.new([{"y", 2}, {"x", 1}]))

    refute GossipSync.content_hash(a, %{"x" => 1}) == GossipSync.content_hash(a, %{"x" => 2})
  end
end
