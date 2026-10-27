defmodule TaskCore.ExecutionWorkerTest do
  use ExUnit.Case, async: true
  alias TaskCore.ExecutionWorker

  test "a timed-out tick is killed and never leaves authority in worker status" do
    parent = self()

    worker =
      start_supervised!(
        {ExecutionWorker,
         tick: fn ->
           send(parent, {:started, self()})

           receive do
             :release -> :ok
           end
         end,
         interval_ms: 60_000,
         timeout_ms: 60_000}
      )

    assert_receive {:started, child}
    monitor = Process.monitor(child)
    active = :sys.get_state(worker).active
    # Deterministic failure injection instead of waiting on a wall clock.
    send(worker, {:tick_timeout, active.job})
    assert_receive {:DOWN, ^monitor, :process, ^child, :killed}
    assert GenServer.call(worker, :status) == %{running: false, last: :timeout}
  end

  test "status formatting never exposes the tick closure or its captured credentials" do
    status = ExecutionWorker.format_status(%{state: %{token: "must-not-leak"}})
    assert status.state == :redacted_execution_worker
  end

  test "callback exceptions are reduced to an error without crashing the worker" do
    parent = self()

    worker =
      start_supervised!(
        {ExecutionWorker,
         tick: fn ->
           send(parent, :started)
           raise "private diagnostic must not be retained"
         end,
         interval_ms: 60_000}
      )

    assert_receive :started
    # Ordered GenServer synchronization after the child exits.
    active = :sys.get_state(worker).active

    if active do
      ref = Process.monitor(active.pid)
      assert_receive {:DOWN, ^ref, :process, _, _}
    end

    assert Process.alive?(worker)
    assert :sys.get_state(worker).last in [:never, :error]
  end

  test "coalesced event wakeups produce one follow-up while a tick is active" do
    parent = self()

    worker =
      start_supervised!(
        {ExecutionWorker,
         tick: fn ->
           send(parent, {:running_tick, self()})

           receive do
             :release -> :ok
           end
         end,
         interval_ms: 60_000,
         timeout_ms: 10_000}
      )

    assert_receive {:running_tick, first}, 1000

    for _ <- 1..50, do: assert(:ok == ExecutionWorker.wake(worker))

    send(first, :release)
    assert_receive {:running_tick, second}, 1000
    refute_receive {:running_tick, _another}, 50

    send(second, :release)
    refute_receive {:running_tick, _another}, 50

    assert Process.alive?(worker)
    assert GenServer.call(worker, :status).last in [:never, :ok]
  end

  test "wakeup cancels a scheduled timer instead of building periodic timer backlog" do
    parent = self()

    worker =
      start_supervised!(
        {ExecutionWorker,
         tick: fn -> send(parent, :tick_observed) end, interval_ms: 60_000, timeout_ms: 10_000}
      )

    assert_receive :tick_observed, 1000
    # Synchronize with the worker after its initial tick is completed.
    wait_for_idle(worker, 30)

    assert :ok = ExecutionWorker.wake(worker)
    assert_receive :tick_observed, 1000
    wait_for_idle(worker, 30)

    refute_receive :tick_observed, 80
  end

  defp wait_for_idle(_worker, 0), do: flunk("worker did not return to idle")

  defp wait_for_idle(worker, retries) do
    case GenServer.call(worker, :status) do
      %{running: false, last: :ok} ->
        :ok

      _ ->
        Process.sleep(10)
        wait_for_idle(worker, retries - 1)
    end
  end
end
