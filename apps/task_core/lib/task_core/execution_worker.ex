defmodule TaskCore.ExecutionWorker do
  @moduledoc """
  Explicitly supervised, generic periodic host tick with a coalesced wakeup.

  Each tick runs in a monitored process with a hard local timeout. A crash or
  timeout retains no in-memory execution authority; the next tick recovers
  from durable CAS state. Wakeups are non-authoritative hints: every tick must
  re-read signed business grants and the operational database.

  A burst of wakeups while running schedules at most one follow-up tick.
  Timers are cancelled on early wakeup so event notifications do not create
  unbounded overlapping periodic scans. Tick return values and exception
  payloads are discarded, never logged or retained in status.
  """
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @doc "Ask for a prompt, coalesced tick. Does not carry any event payload or permission."
  def wake(server), do: GenServer.cast(server, :wake)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    tick = Keyword.fetch!(opts, :tick)
    interval = Keyword.get(opts, :interval_ms, 1_000)
    timeout = Keyword.get(opts, :timeout_ms, 30_000)

    if is_function(tick, 0) and is_integer(interval) and interval in 10..60_000 and
         is_integer(timeout) and timeout in 10..300_000 do
      send(self(), :tick)

      {:ok,
       %{
         tick: tick,
         interval: interval,
         timeout: timeout,
         active: nil,
         scheduled: nil,
         pending: true,
         dirty: false,
         last: :never
       }}
    else
      {:stop, :invalid_execution_worker_options}
    end
  end

  @impl true
  def handle_call(:status, _from, state),
    do: {:reply, %{running: state.active != nil, last: state.last}, state}

  @impl true
  def handle_cast(:wake, %{active: nil, pending: false} = state) do
    cancel_timer(state.scheduled)
    send(self(), :tick)
    {:noreply, %{state | scheduled: nil, pending: true}}
  end

  def handle_cast(:wake, %{active: nil} = state), do: {:noreply, state}

  def handle_cast(:wake, state), do: {:noreply, %{state | dirty: true}}

  @impl true
  def handle_info(:tick, %{active: nil} = state) do
    cancel_timer(state.scheduled)
    parent = self()
    job = make_ref()
    tick = state.tick

    {pid, monitor} =
      :erlang.spawn_opt(
        fn ->
          result =
            try do
              case tick.() do
                {:error, _} -> :error
                _ -> :ok
              end
            rescue
              _ -> :error
            catch
              _, _ -> :error
            end

          send(parent, {:tick_finished, job, result})
        end,
        [:link, :monitor]
      )

    timer = Process.send_after(self(), {:tick_timeout, job}, state.timeout)

    {:noreply,
     %{state | active: %{pid: pid, monitor: monitor, timer: timer, job: job},
       scheduled: nil, pending: false}}
  end

  def handle_info(:tick, state), do: {:noreply, %{state | dirty: true}}

  def handle_info({:tick_finished, job, result}, %{active: %{job: job} = active} = state) do
    Process.demonitor(active.monitor, [:flush])
    cancel_timer(active.timer)
    {:noreply, schedule(%{state | active: nil, last: result})}
  end

  def handle_info({:tick_timeout, job}, %{active: %{job: job} = active} = state) do
    Process.exit(active.pid, :kill)
    Process.demonitor(active.monitor, [:flush])
    {:noreply, schedule(%{state | active: nil, last: :timeout})}
  end

  def handle_info(
        {:DOWN, monitor, :process, _pid, _reason},
        %{active: %{monitor: monitor} = active} = state
      ) do
    cancel_timer(active.timer)
    {:noreply, schedule(%{state | active: nil, last: :error})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{active: %{pid: pid}}), do: Process.exit(pid, :kill)
  def terminate(_reason, _state), do: :ok

  @impl true
  def format_status(status), do: Map.put(status, :state, :redacted_execution_worker)

  defp schedule(%{dirty: true} = state) do
    cancel_timer(state.scheduled)
    send(self(), :tick)
    %{state | dirty: false, scheduled: nil, pending: true}
  end

  defp schedule(state) do
    timer = Process.send_after(self(), :tick, state.interval)
    %{state | scheduled: timer, pending: false}
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer) do
    Process.cancel_timer(timer)
    :ok
  end
end
