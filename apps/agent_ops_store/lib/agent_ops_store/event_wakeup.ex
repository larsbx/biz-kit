defmodule AgentOpsStore.EventWakeup do
  @moduledoc """
  Opt-in, staging-only wakeup bridge from CoopSubstrate's existing ledger
  notifications to the generic TaskCore execution worker.

  CoopSubstrate publishes {:coop_ledger, envelopes} to the cluster :pg group
  only AFTER the canonical log has persisted an accepted event. Those
  notifications are *hints*, not durable event delivery and not authority.
  Any process could send a wakeup-shaped message; the receiver never trusts
  event payloads, principal assertions, identifiers, or policy markers.

  Every wakeup asks the existing coordinator worker to tick, which MUST
  retrieve CURRENT committed, signed replay and re-check domain grants,
  profile approval and the PostgreSQL operational CAS gate before doing
  anything. Bursts are debounced. The existing periodic tick remains the
  recovery path for lost, delayed or out-of-order :pg notifications.

  Neither this module nor the worker installs a production subscriber,
  creates a second event log, performs business writes, or exposes a network
  endpoint. External/federated messages must be separately authenticated,
  admitted to the signed ledger and checked for domain authorization.
  """

  use GenServer

  @default_scope CoopSubstrate.Feed

  def start_link(opts) when is_list(opts) do
    host = Keyword.get(opts, :host)

    if is_atom(host) and function_exported?(host, :environment, 0) and
         host.environment() == :staging do
      GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
    else
      {:error, :staging_only}
    end
  end

  def start_link(_opts), do: {:error, :invalid_wakeup_options}

  @impl true
  def init(opts) do
    target = Keyword.get(opts, :target)
    scope = Keyword.get(opts, :scope, @default_scope)
    cooldown_ms = Keyword.get(opts, :cooldown_ms, 200)

    cond do
      not is_pid(target) or not Process.alive?(target) ->
        {:stop, :invalid_wakeup_target}

      not is_atom(scope) ->
        {:stop, :invalid_ledger_group}

      not is_integer(cooldown_ms) or cooldown_ms not in 10..60_000 ->
        {:stop, :invalid_wakeup_cooldown}

      true ->
        case :pg.join(scope, :ledger, self()) do
          :ok ->
            monitor = Process.monitor(target)

            {:ok,
             %{
               target: target,
               scope: scope,
               monitor: monitor,
               timer: nil,
               cooldown_ms: cooldown_ms
             }}

          _ ->
            {:stop, :ledger_group_unavailable}
        end
    end
  catch
    :exit, _ -> {:stop, :ledger_group_unavailable}
  end

  @impl true
  def handle_info({:coop_ledger, _untrusted_envelopes}, %{timer: nil} = state) do
    timer = Process.send_after(self(), :flush, state.cooldown_ms)
    {:noreply, %{state | timer: timer}}
  end

  def handle_info({:coop_ledger, _untrusted_envelopes}, state), do: {:noreply, state}

  def handle_info(:flush, %{target: target} = state) do
    if Process.alive?(target), do: TaskCore.ExecutionWorker.wake(target)
    {:noreply, %{state | timer: nil}}
  end

  def handle_info(
        {:DOWN, monitor, :process, target, _reason},
        %{monitor: monitor, target: target} = state
      ) do
    {:stop, :normal, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{scope: scope}) do
    :pg.leave(scope, :ledger, self())
    :ok
  catch
    :exit, _ -> :ok
  end

  def terminate(_reason, _state), do: :ok
end
