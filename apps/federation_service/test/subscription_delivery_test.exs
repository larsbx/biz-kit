defmodule FederationService.SubscriptionDeliveryTest do
  use ExUnit.Case, async: true

  alias FederationCore.Subscriptions, as: Wire
  alias FederationService.{Store, SubscriptionDelivery}
  import FederationService.TestHelpers

  @alpha "https://alpha.example/actors/shop"
  @beta "https://beta.example/actors/shop"
  @receipt "host-verified-authorization-reference"

  setup do
    dir = temp()
    {:ok, store} = Store.start_link(directory: dir)

    config =
      FederationService.config!(
        actor: @alpha,
        peers: [@beta],
        store: store,
        private_key: key()
      )

    on_exit(fn ->
      stop_store(store)
      File.rm_rf!(dir)
    end)

    %{store: store, config: config, dir: dir}
  end

  test "approved inbound Follow atomically journals its exact response, without an HTTP command", c do
    {:ok, follow} = Wire.follow(@beta, @alpha, @beta <> "/activities/one")

    assert {:ok, :pending} =
             Store.call(c.store, {:subscription, {:receive, follow, @beta, @alpha, 1000}})

    assert {:ok, :accepted} =
             FederationService.respond_follow(c.config, follow["id"], :accept, "accept-one", @receipt, 1001)

    data = Store.call(c.store, :snapshot)
    assert data.subscriptions[follow["id"]].status == :accepted
    assert map_size(data.subscription_outbox) == 1
    [{id, row}] = Enum.to_list(data.subscription_outbox)
    assert row.activity["type"] == "Accept"
    assert row.activity["object"] == follow
    assert row.destination == @beta
    assert row.status == :pending
    assert SubscriptionDelivery.ready?(data, c.config, row)
    assert {:error, :subscription_decision_refused} =
             FederationService.respond_follow(c.config, follow["id"], :accept, "other", @receipt, 1002)

    assert :ok = Store.call(c.store, {:subscription_delivery, id, false, 1001})
    failed = Store.call(c.store, :snapshot).subscription_outbox[id]
    assert failed.status == :pending and failed.attempts == 1 and failed.next_at > 1001

    GenServer.stop(c.store)
    {:ok, restarted} = Store.start_link(directory: c.dir)
    assert Store.call(restarted, :snapshot).subscription_outbox[id] == failed

    assert :ok = Store.call(restarted, {:subscription_delivery, id, true, 1004})
    assert Store.call(restarted, :snapshot).subscription_outbox[id].status == :delivered
    assert {:error, :unknown_or_settled_subscription_delivery} =
             Store.call(restarted, {:subscription_delivery, id, true, 1005})

    GenServer.stop(restarted)
  end

  test "local Follow must precede Undo even if cancelled before first network delivery", c do
    assert {:ok, :begun} = FederationService.follow(c.config, @beta, "source-1", 1000)
    s = Store.call(c.store, :snapshot)
    [{id, follow_row}] = Enum.to_list(s.subscription_outbox)
    assert follow_row.activity["type"] == "Follow"
    assert SubscriptionDelivery.ready?(s, c.config, follow_row)

    assert {:ok, :withdrawn} =
             FederationService.undo_follow(c.config, id, "undo-source-1", @receipt, 1001)

    after_cancel = Store.call(c.store, :snapshot)
    [{_undo_id, undo_row}] =
      Enum.reject(after_cancel.subscription_outbox, fn {row_id, _} -> row_id == id end)

    assert SubscriptionDelivery.ready?(after_cancel, c.config, follow_row)
    refute SubscriptionDelivery.ready?(after_cancel, c.config, undo_row)

    assert :ok = Store.call(c.store, {:subscription_delivery, id, true, 1002})
    assert SubscriptionDelivery.ready?(Store.call(c.store, :snapshot), c.config, undo_row)

    assert :ok = Store.call(c.store, {:block, "beta.example", true})
    refute SubscriptionDelivery.ready?(Store.call(c.store, :snapshot), c.config, undo_row)
  end

  test "host API rejects unconfigured targets and cannot forge approval for outgoing rows", c do
    assert {:error, :subscription_follow_refused} =
             FederationService.follow(c.config, "https://unknown.example/actors/shop", "bad")

    assert {:ok, :begun} = FederationService.follow(c.config, @beta, "valid", 1000)
    id = hd(Map.keys(Store.call(c.store, :snapshot).subscriptions))

    assert {:error, :subscription_host_refused} =
             FederationService.respond_follow(c.config, id, :accept, "bad-grant", @receipt)

    assert {:ok, :duplicate} = FederationService.follow(c.config, @beta, "valid", 1000)
    assert map_size(Store.call(c.store, :snapshot).subscription_outbox) == 1
  end

  test "blocked peer never receives a newly locally accepted response", c do
    {:ok, follow} = Wire.follow(@beta, @alpha, @beta <> "/activities/follow-2")

    assert {:ok, :pending} =
             Store.call(c.store, {:subscription, {:receive, follow, @beta, @alpha, 1000}})

    Store.call(c.store, {:block, @beta, true})

    assert {:error, :subscription_host_refused} =
             FederationService.respond_follow(c.config, follow["id"], :accept, "blocked", @receipt)

    assert Store.call(c.store, :snapshot).subscription_outbox == %{}
  end
end
