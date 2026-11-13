defmodule ProcurementHost.AdmissionTest do
  use ExUnit.Case, async: true
  alias ProcurementHost.Admission

  defp operation(results) do
    key = make_ref()
    Process.put(key, {results, 0})
    fun = fn ->
      {[next | remaining], count} = Process.get(key)
      Process.put(key, {remaining, count + 1})
      next
    end
    {fun, fn -> elem(Process.get(key), 1) end}
  end

  test "successful calls are not repeated" do
    {call, count} = operation([{:ok, :receipt}])
    assert Admission.run(call) == {:ok, :receipt}
    assert count.() == 1
  end

  test "snapshot clock refusal is retried, bounded by three attempts" do
    stale = {:error, :stale_procurement_admission_time}
    {call, count} = operation([stale, stale, {:ok, :snapshot}])
    assert Admission.run(call) == {:ok, :snapshot}
    assert count.() == 3
  end

  test "singleton write rejection is handled in its actual Log error shape" do
    stale = {:error, {:reject, 0, :stale_procurement_admission_time}}
    {call, count} = operation([stale, {:ok, :receipt}])
    assert Admission.run(call) == {:ok, :receipt}
    assert count.() == 2
  end

  test "exhaustion returns the refusal without a fourth attempt" do
    for stale <- [{:error, :stale_procurement_admission_time},
                  {:error, {:reject, 0, :stale_procurement_admission_time}}] do
      {call, count} = operation([stale, stale, stale])
      assert Admission.run(call) == stale
      assert count.() == 3
    end
  end

  test "revocation observed after a clock refusal immediately stops retrying" do
    denied = {:error, :procurement_forbidden}
    {call, count} = operation([{:error, :stale_procurement_admission_time}, denied])
    assert Admission.run(call) == denied
    assert count.() == 2
  end

  test "other refusals and uncertain outcomes are never retried" do
    for reason <- [:procurement_forbidden, :procurement_authority_expired_or_replaced,
                   :stale_version, :idempotency_conflict, :timeout,
                   {:store_append_failed, :wrong_expected_version},
                   {:reject, 0, :quote_expired},
                   {:reject, 1, :stale_procurement_admission_time}] do
      {call, count} = operation([{:error, reason}])
      assert Admission.run(call) == {:error, reason}
      assert count.() == 1
    end
  end

  test "exceptions propagate rather than becoming retries or success" do
    assert_raise RuntimeError, "unknown outcome", fn ->
      Admission.run(fn -> raise "unknown outcome" end)
    end
  end

  test "GenServer timeout exits propagate rather than replaying the command" do
    assert catch_exit(Admission.run(fn -> exit({:timeout, :synthetic_call}) end)) ==
      {:timeout, :synthetic_call}
  end
end
