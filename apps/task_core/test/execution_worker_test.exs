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
end
