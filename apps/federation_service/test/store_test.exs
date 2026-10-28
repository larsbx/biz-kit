defmodule FederationService.StoreTest do
  use ExUnit.Case, async: true
  alias FederationService.{Store, Signature}
  import FederationService.TestHelpers
  alias FederationCore.Marketplace, as: M

  setup do
    dir = temp()
    {:ok, s} = Store.start_link(directory: dir)

    on_exit(fn ->
      stop_store(s)
      File.rm_rf!(dir)
    end)

    %{s: s, dir: dir}
  end

  test "acknowledged inbox survives restart and retry is a no-op; conflicting activity refused",
       %{s: s, dir: dir} do
    a = activity(metadata())
    assert {:ok, :queued} = enqueue(s, a)
    GenServer.stop(s)
    {:ok, s} = Store.start_link(directory: dir)
    assert {:ok, :duplicate} = enqueue(s, a)
    changed = put_in(a, ["object", "name"], "Different")
    assert {:error, :activity_conflict} = enqueue(s, changed)
    assert :ok = Store.call(s, {:project, a["id"], metadata(), 1001})
    snap = Store.call(s, :snapshot)
    assert map_size(snap.remote) == 1
    assert snap.inbox[a["id"]].status == :applied
    GenServer.stop(s)
    {:ok, s} = Store.start_link(directory: dir)
    assert Store.call(s, :snapshot).remote == snap.remote
    GenServer.stop(s)
  end

  test "revision monotonicity, binding, ownership and terminal withdrawal", %{s: s} do
    m = metadata()
    a = activity(m)
    enqueue(s, a)
    assert :ok = Store.call(s, {:project, a["id"], m, 1000})

    for {rev, id, outcome} <- [
          {2, "two", :ok},
          {1, "old", {:error, :stale_revision}},
          {2, "equivocation", {:error, :stale_revision}}
        ] do
      m2 = metadata(m["seller"], rev)
      a2 = activity(m2, id, :update)
      enqueue(s, a2)
      assert Store.call(s, {:project, a2["id"], m2, 1001}) == outcome
    end

    other = metadata("https://alpha.example/actors/other", 3)
    a2 = activity(other, "steal", :update)
    enqueue(s, a2)
    assert {:error, :owner_substitution} = Store.call(s, {:project, a2["id"], other, 1002})
    {:ok, del} = M.withdraw(m["seller"], m["id"], m["seller"] <> "/activities/delete")
    enqueue(s, del)
    assert :ok = Store.call(s, {:project, del["id"], nil, 1003})
    m3 = metadata(m["seller"], 3)
    a3 = activity(m3, "resurrect", :update)
    enqueue(s, a3)
    assert {:error, :withdrawn} = Store.call(s, {:project, a3["id"], m3, 1004})
    assert Store.call(s, :snapshot).remote[m["id"]].withdrawn
  end

  test "delete before create prevents delayed resurrection and wrong metadata ID refused", %{s: s} do
    m = metadata()
    {:ok, del} = M.withdraw(m["seller"], m["id"], m["seller"] <> "/activities/delete")
    enqueue(s, del)
    Store.call(s, {:project, del["id"], nil, 1000})
    a = activity(m)
    enqueue(s, a)
    assert {:error, :withdrawn} = Store.call(s, {:project, a["id"], m, 1001})
    m2 = metadata(m["seller"], 0, %{listing_id: "https://alpha.example/listings/other"})
    a2 = activity(m2, "other")
    enqueue(s, a2)
    assert {:error, :invalid_metadata_binding} = Store.call(s, {:project, a2["id"], m, 1001})
  end

  test "moderation is durable and removes indexed listings from combined search", %{
    s: s,
    dir: dir
  } do
    m = metadata()
    a = activity(m)
    enqueue(s, a)
    Store.call(s, {:project, a["id"], m, 1000})

    config =
      FederationService.config!(
        actor: "https://beta.example/actors/shop",
        private_key: key(),
        store: s
      )

    assert [%{source: "alpha.example", local: false, stale: false}] =
             FederationService.search(config, "part", 1001)

    assert [%{stale: true}] = FederationService.search(config, "part", 5000)
    Store.call(s, {:block, "alpha.example", true})
    assert [] = FederationService.search(config)
    GenServer.stop(s)
    {:ok, s} = Store.start_link(directory: dir)
    assert Store.call(s, :snapshot).blocks["alpha.example"]
    GenServer.stop(s)
  end

  test "publications and retry receipts are journaled without business capabilities", %{
    s: s,
    dir: dir
  } do
    config =
      FederationService.config!(
        actor: metadata()["seller"],
        store: s,
        private_key: key(),
        peers: ["https://beta.example/actors/shop"]
      )

    m = metadata()
    assert {:ok, :published} = FederationService.publish(config, "source-event-one", m)
    assert {:ok, :duplicate} = FederationService.publish(config, "source-event-one", m)

    assert {:ok, :duplicate} =
             FederationService.publish(%{config | peers: []}, "source-event-one", m)

    assert {:ok, :duplicate} =
             FederationService.publish(
               %{config | peers: ["https://new.example/actors/shop"]},
               "source-event-one",
               m
             )

    assert {:error, :event_conflict} =
             FederationService.publish(config, "source-event-one", metadata(m["seller"], 1))

    assert {:error, :publication_refused} =
             FederationService.publish(
               config,
               "foreign",
               metadata("https://evil.example/actors/shop")
             )

    s0 = Store.call(s, :snapshot)
    assert map_size(s0.outbox) == 1 and map_size(s0.publications) == 1
    [{id, _}] = Enum.to_list(s0.outbox)
    Store.call(s, {:delivery, id, 0, false, 1000})
    GenServer.stop(s)
    {:ok, s} = Store.start_link(directory: dir)
    assert Store.call(s, :snapshot).outbox[id].attempts == 1
    assert Store.call(s, :snapshot).outbox[id].status == :pending
    GenServer.stop(s)
    assert Signature.validate_key(Signature.public_key(config.private_key)) == :ok
  end

  test "freshness requires identical origin metadata; replays and changed snapshots cannot refresh it",
       %{s: s} do
    m = metadata()
    a = activity(m)
    enqueue(s, a)
    Store.call(s, {:project, a["id"], m, 1000})
    assert {:ok, :duplicate} = enqueue(s, a, 5000)
    assert Store.call(s, :snapshot).remote[m["id"]].verified_at == 1000
    Store.call(s, {:refresh, m["id"], metadata(m["seller"], 1), 5000})
    assert Store.call(s, :snapshot).remote[m["id"]].verified_at == 1000
    Store.call(s, {:refresh, m["id"], m, 5001})
    assert Store.call(s, :snapshot).remote[m["id"]].verified_at == 5001
    Store.call(s, {:block, m["seller"], true})
    Store.call(s, {:refresh, m["id"], m, 6000})
    assert Store.call(s, :snapshot).remote[m["id"]].verified_at == 5001
  end

  test "rate limits refuse excess traffic", %{s: s} do
    assert :ok = Store.call(s, {:rate, :global, 1, 1000})
    assert {:error, :rate_limited} = Store.call(s, {:rate, :global, 1, 1001})
    assert :ok = Store.call(s, {:rate, :global, 1, 1080})
  end
end
