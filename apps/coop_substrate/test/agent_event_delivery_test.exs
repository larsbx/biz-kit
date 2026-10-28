defmodule CoopSubstrate.AgentEventDeliveryTest do
  use ExUnit.Case, async: true
  alias CoopSubstrate.AgentEventDelivery, as: Delivery

  defp ports do
    Process.put(:trace, [])

    %{
      read: fn n ->
        Process.put(:trace, Process.get(:trace) ++ [:read])
        {:ok, %{seq: n}}
      end,
      register: fn _ ->
        Process.put(:trace, Process.get(:trace) ++ [:committed_registration])
        {:ok, :new}
      end,
      ack: fn _ ->
        Process.put(:trace, Process.get(:trace) ++ [:ack])
        :ok
      end
    }
  end

  test "ack follows completed durable registration" do
    assert :ok = Delivery.deliver(1, ports())
    assert Process.get(:trace) == [:read, :committed_registration, :ack]
  end

  test "read failure cannot register or ack" do
    p = Map.put(ports(), :read, fn _ -> {:error, :invalid_source} end)
    assert {:error, :invalid_source} = Delivery.deliver(1, p)
    assert Process.get(:trace) == []
  end

  test "registration failure cannot ack" do
    p = Map.put(ports(), :register, fn _ -> {:error, :db_failed} end)
    assert {:error, :db_failed} = Delivery.deliver(1, p)
    assert Process.get(:trace) == [:read]
  end

  test "lost ack repeats idempotent registration before another ack" do
    p = Map.put(ports(), :ack, fn _ -> {:error, :ack_lost} end)
    assert {:error, :ack_lost} = Delivery.deliver(1, p)
    p = %{p | register: fn _ -> {:ok, :existing} end, ack: fn _ -> :ok end}
    assert :ok = Delivery.deliver(1, p)
  end

  test "a crash after commit cannot acknowledge delivery" do
    p =
      Map.put(ports(), :register, fn _ ->
        Process.put(:trace, Process.get(:trace) ++ [:committed_registration])
        throw(:simulated_crash)
      end)

    assert catch_throw(Delivery.deliver(1, p)) == :simulated_crash
    assert Process.get(:trace) == [:read, :committed_registration]
  end
end
