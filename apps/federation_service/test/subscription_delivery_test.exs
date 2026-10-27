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
        private_key: key(),
        approval_verifier: fn _local, _follow, _decision, receipt, _now ->
          if receipt == @receipt, do: :ok, else: {:error, :untrusted_receipt}
        end
      )

    on_exit(fn ->
      stop_store(store)
      File.rm_rf!(dir)
    end)

    %{store: store, config: config, dir: dir}
  end

  test "pre-outbox Follow fixture recovers without inventing an acknowledgment", c do
    GenServer.stop(c.store)
    {:ok, follow} = Wire.follow(@alpha, @beta, @alpha <> "/activities/legacy")
    legacy_follow_journal(c.dir, follow)
    {:ok, upgraded} = Store.start_link(directory: c.dir)
    config = %{c.config | store: upgraded}
    on_exit(fn -> stop_store(upgraded) end)
    id = follow["id"]

    assert {:ok, :duplicate} = Store.call(upgraded, {:subscription, {:begin, follow, 1000}})

    before_cancel = Store.call(upgraded, :snapshot)

    assert {:error, :unverified_local_authority} =
             FederationService.undo_follow(
               %{config | approval_verifier: nil},
               id,
               "no-grant",
               @receipt,
               1001
             )

    assert Store.call(upgraded, :snapshot) == before_cancel

    assert {:ok, :withdrawn} =
             FederationService.undo_follow(config, id, "legacy-undo", @receipt, 1001)

    data = Store.call(upgraded, :snapshot)
    recovered = data.subscription_outbox[id]
    assert recovered.activity == follow
    assert recovered.status == :pending and recovered.attempts == 0
    refute Map.has_key?(recovered, :last_delivery)
    [{undo_id, undo}] = Enum.reject(data.subscription_outbox, fn {key, _} -> key == id end)
    assert SubscriptionDelivery.ready?(data, config, recovered)
    refute SubscriptionDelivery.ready?(data, config, undo)

    # A failed attempt and restart cannot manufacture Follow-before-Undo progress.
    assert :ok = Store.call(upgraded, {:subscription_delivery, id, false, 1002})
    failed = Store.call(upgraded, :snapshot)
    refute SubscriptionDelivery.ready?(failed, config, undo)
    GenServer.stop(upgraded)
    {:ok, restarted} = Store.start_link(directory: c.dir)
    on_exit(fn -> stop_store(restarted) end)
    assert Store.call(restarted, :snapshot) == failed
    config = %{config | store: restarted}

    assert :ok = Store.call(restarted, {:subscription_delivery, id, true, 1004})
    assert SubscriptionDelivery.ready?(Store.call(restarted, :snapshot), config, undo)
    assert :ok = Store.call(restarted, {:subscription_delivery, undo_id, true, 1005})
    assert {:ok, :duplicate} = Store.call(restarted, {:subscription, {:begin, follow, 1006}})
    final = Store.call(restarted, :snapshot)
    assert final.subscriptions[id].status == :withdrawn
    GenServer.stop(restarted)
    bytes = File.stat!(c.dir <> "/discovery.log").size
    {:ok, settled} = Store.start_link(directory: c.dir)
    on_exit(fn -> stop_store(settled) end)
    assert Store.call(settled, :snapshot) == final
    assert File.stat!(c.dir <> "/discovery.log").size == bytes
  end

  test "upgrade preserves terminal rows and only recovers retained pending withdrawal work", c do
    GenServer.stop(c.store)

    for {status, suffix} <- [{:accepted, "active"}, {:rejected, "no"}, {:withdrawn, "gone"}] do
      {:ok, follow} =
        Wire.follow(@alpha, @beta <> "/" <> suffix, @alpha <> "/activities/" <> suffix)

      legacy_follow_journal(c.dir, follow, status)
    end

    # Reproduce the already-upgraded failure: legacy Follow + new pending Undo,
    # but no Follow effect. This is a real cancellation transaction from #164.
    {:ok, stranded} = Wire.follow(@alpha, @beta, @alpha <> "/activities/stranded")
    legacy_follow_journal(c.dir, stranded)
    id = stranded["id"]
    receipt = %{hash: :crypto.hash(:sha256, :erlang.term_to_binary(stranded)), follow_id: id}

    row = %{
      direction: :outgoing,
      follower: @alpha,
      target: @beta,
      follow: stranded,
      status: :pending,
      started_at: 1000,
      authority: nil
    }

    before = %{
      subscriptions: %{id => row},
      subscription_events: %{id => receipt},
      subscription_outbox: %{}
    }

    {:ok, changes, {:ok, :withdrawn}} =
      FederationService.SubscriptionState.plan(
        before,
        {:cancel, id, id <> "-undo", @receipt, 1001}
      )

    append_journal(c.dir, [{:transaction, changes}])

    {:ok, upgraded} = Store.start_link(directory: c.dir)
    on_exit(fn -> stop_store(upgraded) end)
    data = Store.call(upgraded, :snapshot)
    assert map_size(data.subscription_outbox) == 3
    assert data.subscription_outbox[@alpha <> "/activities/active"].status == :pending
    refute Map.has_key?(data.subscription_outbox, @alpha <> "/activities/no")
    refute Map.has_key?(data.subscription_outbox, @alpha <> "/activities/gone")
    assert data.subscriptions[@alpha <> "/activities/no"].status == :rejected
    assert data.subscriptions[@alpha <> "/activities/gone"].status == :withdrawn
    assert data.subscriptions[id].status == :withdrawn
    assert data.subscription_outbox[id].status == :pending
    config = %{c.config | store: upgraded}
    refute SubscriptionDelivery.ready?(data, config, data.subscription_outbox[id <> "-undo"])
    assert :ok = Store.call(upgraded, {:subscription_delivery, id, true, 1002})
    data = Store.call(upgraded, :snapshot)
    assert SubscriptionDelivery.ready?(data, config, data.subscription_outbox[id <> "-undo"])
    assert {:ok, []} = FederationService.SubscriptionState.recover_outbox(data)
  end

  test "recovery requires exact original receipts and fails closed at capacity", c do
    {:ok, follow} = Wire.follow(@alpha, @beta, @alpha <> "/activities/proof")
    assert {:ok, :begun} = Store.call(c.store, {:subscription, {:begin, follow, 1000}})
    modern = Store.call(c.store, :snapshot)
    assert {:ok, []} = FederationService.SubscriptionState.recover_outbox(modern)
    legacy = %{modern | subscription_outbox: %{}}
    assert {:ok, [_]} = FederationService.SubscriptionState.recover_outbox(legacy)

    assert {:ok, []} =
             FederationService.SubscriptionState.recover_outbox(%{
               legacy
               | subscription_events: %{}
             })

    forged = put_in(legacy, [:subscription_events, follow["id"], :hash], <<0>>)
    assert {:ok, []} = FederationService.SubscriptionState.recover_outbox(forged)
    incoming = put_in(legacy, [:subscriptions, follow["id"], :direction], :incoming)
    assert {:ok, []} = FederationService.SubscriptionState.recover_outbox(incoming)
    full = %{legacy | subscription_outbox: Map.new(1..10_000, &{to_string(&1), %{}})}

    assert {:error, :subscription_outbox_capacity} =
             FederationService.SubscriptionState.recover_outbox(full)

    assert Store.call(c.store, :snapshot) == modern
  end

  test "local approval refuses absent or failing verifier before committing a reply", c do
    {:ok, follow} = Wire.follow(@beta, @alpha, @beta <> "/activities/no-approval")

    assert {:ok, :pending} =
             Store.call(c.store, {:subscription, {:receive, follow, @beta, @alpha, 1000}})

    unconfigured = %{c.config | approval_verifier: nil}

    assert {:error, :unverified_local_authority} =
             FederationService.respond_follow(unconfigured, follow["id"], :accept, "no", @receipt)

    assert {:error, :unverified_local_authority} =
             FederationService.respond_follow(c.config, follow["id"], :accept, "bad", "forged")

    assert Store.call(c.store, :snapshot).subscription_outbox == %{}
    assert Store.call(c.store, :snapshot).subscriptions[follow["id"]].status == :pending
  end

  test "approved inbound Follow atomically journals its exact response, without an HTTP command",
       c do
    {:ok, follow} = Wire.follow(@beta, @alpha, @beta <> "/activities/one")

    assert {:ok, :pending} =
             Store.call(c.store, {:subscription, {:receive, follow, @beta, @alpha, 1000}})

    assert {:ok, :accepted} =
             FederationService.respond_follow(
               c.config,
               follow["id"],
               :accept,
               "accept-one",
               @receipt,
               1001
             )

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
             FederationService.respond_follow(
               c.config,
               follow["id"],
               :accept,
               "other",
               @receipt,
               1002
             )

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

    before = Store.call(c.store, :snapshot).subscription_outbox
    FederationService.deliver_subscriptions(c.config, 1003)
    assert Store.call(c.store, :snapshot).subscription_outbox == before
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
             FederationService.respond_follow(
               c.config,
               follow["id"],
               :accept,
               "blocked",
               @receipt
             )

    assert Store.call(c.store, :snapshot).subscription_outbox == %{}
  end
end
