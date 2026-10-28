defmodule TaskCore.DispatcherTest do
  use ExUnit.Case, async: true

  alias TaskCore.Dispatcher

  defp ports do
    Process.put(:row, nil)
    Process.put(:launches, 0)
    Process.put(:prepares, 0)
    Process.put(:deny_at, nil)
    Process.put(:launch_error, false)
    Process.put(:attach_error, false)
    plan = %{effect_id: "effect-1", immutable_intent: "signed-1"}

    %{
      prepare: fn _key ->
        count = Process.get(:prepares) + 1
        Process.put(:prepares, count)
        if Process.get(:deny_at) == count, do: {:error, :revoked}, else: {:ok, plan}
      end,
      register: fn ^plan ->
        if Process.get(:row) do
          {:ok, :existing}
        else
          Process.put(:row, %{phase: "pending", version: 1})
          {:ok, :new}
        end
      end,
      snapshot: fn _ -> {:ok, Process.get(:row)} end,
      claim: fn _, version ->
        if Process.get(:row) == %{phase: "pending", version: version} do
          Process.put(:row, %{phase: "leased", version: version + 1})
          {:ok, %{version: version + 1, epoch: 1, token: "host-only"}}
        else
          {:error, :claim_refused}
        end
      end,
      request_cancel: fn _, version ->
        Process.put(:row, %{phase: "cancel_requested", version: version + 1})
        {:ok, version + 1}
      end,
      validate_lease: fn _, _ -> :ok end,
      launch: fn ^plan ->
        Process.put(:launches, Process.get(:launches) + 1)
        if Process.get(:launch_error), do: raise("lost response"), else: {:ok, "backend-1"}
      end,
      attach: fn _, lease, "backend-1" ->
        if Process.get(:attach_error) do
          {:error, :db_unavailable}
        else
          Process.put(:row, %{phase: "leased", version: lease.version + 1})
          {:ok, lease.version + 1}
        end
      end
    }
  end

  test "repeated ledger scans enqueue one durable effect before any launch" do
    p = ports()
    assert {:ok, %{disposition: :new}} = Dispatcher.enqueue(:key, p)
    assert {:ok, %{disposition: :existing}} = Dispatcher.enqueue(:key, p)
    assert Process.get(:row).phase == "pending"
    assert Process.get(:launches) == 0
  end

  test "duplicate delivery never launches twice" do
    p = ports()
    assert {:ok, %{disposition: :dispatched}} = Dispatcher.deliver(:key, p)
    assert {:ok, %{disposition: :already_dispatched}} = Dispatcher.deliver(:key, p)
    assert Process.get(:launches) == 1
  end

  test "revocation before delivery neither registers nor launches an effect" do
    p = ports()
    Process.put(:deny_at, 1)
    assert {:error, :revoked} = Dispatcher.deliver(:key, p)
    assert Process.get(:row) == nil
    assert Process.get(:launches) == 0
  end

  test "revocation during claim fences the attempt before launch" do
    p = ports()
    Process.put(:deny_at, 2)
    assert {:error, :authority_changed_after_claim} = Dispatcher.deliver(:key, p)
    assert Process.get(:row).phase == "cancel_requested"
    assert Process.get(:launches) == 0
  end

  test "lost backend response leaves an abandoned lease for reconciliation" do
    p = ports()
    Process.put(:launch_error, true)
    assert {:error, :launch_requires_reconciliation} = Dispatcher.deliver(:key, p)
    assert Process.get(:row).phase == "leased"
    assert {:ok, %{disposition: :already_dispatched}} = Dispatcher.deliver(:key, p)
    assert Process.get(:launches) == 1
  end

  test "crash between external launch and attachment never licenses relaunch" do
    p = ports()
    Process.put(:attach_error, true)
    assert {:error, :launch_requires_reconciliation} = Dispatcher.deliver(:key, p)
    Process.put(:attach_error, false)
    assert {:ok, %{disposition: :already_dispatched}} = Dispatcher.deliver(:key, p)
    assert Process.get(:launches) == 1
  end

  test "a lease invalidated during post-claim authorization cannot launch" do
    p = Map.put(ports(), :validate_lease, fn _, _ -> {:error, :launch_lease_invalid} end)
    assert {:error, :launch_lease_invalid} = Dispatcher.deliver(:key, p)
    assert Process.get(:launches) == 0
    assert Process.get(:row).phase == "leased"
  end
end
