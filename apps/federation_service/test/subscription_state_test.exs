defmodule FederationService.SubscriptionStateTest do
  use ExUnit.Case, async: true

  alias FederationCore.Subscriptions, as: Wire
  alias FederationService.{Store, SubscriptionState}
  import FederationService.TestHelpers

  @buyer "https://buyer.example/actors/buyer"
  @seller "https://seller.example/actors/shop"
  @follow_id "https://buyer.example/activities/follow-1"
  @accept_id "https://seller.example/activities/accept-1"
  @undo_id "https://buyer.example/activities/undo-1"
  @receipt "verified-local-grant-receipt-1"

  defp follow! do
    {:ok, f} = Wire.follow(@buyer, @seller, @follow_id)
    f
  end

  defp send!(store, intent), do: Store.call(store, {:subscription, intent})
  defp data(store), do: Store.call(store, :snapshot)

  setup do
    dir = temp()
    {:ok, store} = Store.start_link(directory: dir)

    on_exit(fn ->
      stop_store(store)
      File.rm_rf!(dir)
    end)

    %{store: store, dir: dir}
  end

  test "outbound Follow needs an exact local intent and correlates authenticated reply", c do
    f = follow!()
    assert {:ok, :begun} = send!(c.store, {:begin, f, 1000})
    assert {:ok, :duplicate} = send!(c.store, {:begin, f, 1000})
    {:ok, accepted} = Wire.respond(:accept, @seller, f, @accept_id)

    assert {:error, :subscription_receive_refused} =
             send!(c.store, {:receive, accepted, @buyer, @buyer, 1001})

    assert {:ok, :accepted} = send!(c.store, {:receive, accepted, @seller, @buyer, 1001})
    assert {:ok, :duplicate} = send!(c.store, {:receive, accepted, @seller, @buyer, 1001})
    assert data(c.store).subscriptions[@follow_id].status == :accepted
    assert {:ok, :withdrawn} = send!(c.store, {:cancel, @follow_id, @undo_id, @receipt, 1002})
    assert data(c.store).subscriptions[@follow_id].status == :withdrawn
  end

  test "remote Follow remains pending until explicit host-only decision", c do
    f = follow!()
    assert {:ok, :pending} = send!(c.store, {:receive, f, @buyer, @seller, 2000})
    assert data(c.store).subscriptions[@follow_id].authority == nil

    assert {:error, :subscription_decision_refused} =
             send!(c.store, {:decide, @follow_id, :accept, @accept_id, "", 2001})

    assert {:ok, :accepted} =
             send!(c.store, {:decide, @follow_id, :accept, @accept_id, @receipt, 2001})

    assert data(c.store).subscriptions[@follow_id].authority == @receipt
    {:ok, undo} = Wire.undo(@buyer, f, @undo_id)
    assert {:ok, :withdrawn} = send!(c.store, {:receive, undo, @buyer, @seller, 2002})
    assert {:ok, :duplicate} = send!(c.store, {:receive, undo, @buyer, @seller, 2002})

    # A fresh Follow ID is allowed after the old relationship was withdrawn;
    # it never reactivates the old terminal record.
    assert {:ok, :pending} =
             send!(
               c.store,
               {:receive, Map.put(f, "id", @follow_id <> "-2"), @buyer, @seller, 2003}
             )

    assert data(c.store).subscriptions[@follow_id].status == :withdrawn
  end

  test "restart preserves pending decisions, terminal status and replay evidence", c do
    f = follow!()
    assert {:ok, :pending} = send!(c.store, {:receive, f, @buyer, @seller, 1000})
    GenServer.stop(c.store)
    {:ok, reopened} = Store.start_link(directory: c.dir)
    assert data(reopened).subscriptions[@follow_id].status == :pending

    assert {:ok, :rejected} =
             send!(reopened, {:decide, @follow_id, :reject, @accept_id, @receipt, 1001})

    GenServer.stop(reopened)
    {:ok, again} = Store.start_link(directory: c.dir)
    assert data(again).subscriptions[@follow_id].status == :rejected
    assert {:ok, :duplicate} = send!(again, {:receive, f, @buyer, @seller, 1002})

    {:ok, undo} = Wire.undo(@buyer, f, @undo_id)

    assert {:error, :subscription_undo_refused} =
             send!(again, {:receive, undo, @buyer, @seller, 1002})

    GenServer.stop(again)
  end

  test "unrequested Accept, swapped sender, altered object and old replies refuse", c do
    f = follow!()
    {:ok, reply} = Wire.respond(:accept, @seller, f, @accept_id)

    assert {:error, :unsolicited_subscription_reply} =
             send!(c.store, {:receive, reply, @seller, @buyer, 1000})

    assert {:ok, :begun} = send!(c.store, {:begin, f, 1000})

    assert {:error, :subscription_receive_refused} =
             send!(c.store, {:receive, reply, @buyer, @buyer, 1000})

    changed = put_in(reply, ["object", "id"], "https://buyer.example/activities/other")

    assert {:error, :unsolicited_subscription_reply} =
             send!(c.store, {:receive, changed, @seller, @buyer, 1000})

    assert {:ok, :accepted} = send!(c.store, {:receive, reply, @seller, @buyer, 1001})

    {:ok, reject} =
      Wire.respond(:reject, @seller, f, "https://seller.example/activities/reject-late")

    assert {:error, :unsolicited_subscription_reply} =
             send!(c.store, {:receive, reject, @seller, @buyer, 1002})
  end

  test "duplicate activity ID conflict and duplicate relationship refuse without writing", c do
    f = follow!()
    assert {:ok, :begun} = send!(c.store, {:begin, f, 1000})

    {:ok, another} = Wire.follow(@buyer, @seller, @follow_id <> "-new")
    assert {:error, :subscription_begin_refused} = send!(c.store, {:begin, another, 1001})
    before = data(c.store)

    assert {:error, :subscription_begin_refused} =
             send!(c.store, {:begin, Map.put(f, "object", @buyer), 1002})

    assert data(c.store) == before
    assert map_size(data(c.store).subscription_events) == 1
  end

  test "invalid host commands cannot fabricate permissions or unsolicited cancels", c do
    f = follow!()

    assert {:error, :subscription_decision_refused} =
             send!(c.store, {:decide, @follow_id, :accept, @accept_id, @receipt, 1001})

    assert {:error, :subscription_cancel_refused} =
             send!(c.store, {:cancel, @follow_id, @undo_id, @receipt, 1001})

    assert {:error, :unsupported_subscription_intent} =
             send!(c.store, {:write_ledger, f, 1000})

    assert data(c.store).subscriptions == %{}
    assert data(c.store).subscription_events == %{}
  end

  test "planning remains pure and exposes exact journal changes", _c do
    data = %{subscriptions: %{}, subscription_events: %{}}
    {:ok, changes, {:ok, :begun}} = SubscriptionState.plan(data, {:begin, follow!(), 1000})
    assert Enum.map(changes, &elem(&1, 0)) == [:subscriptions, :subscription_events]
    assert data == %{subscriptions: %{}, subscription_events: %{}}
  end
end
