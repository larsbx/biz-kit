defmodule BizKit.Cluster.Singleton do
  @moduledoc """
  One process of a module for the whole cluster, registered in `:global`
  under the module's name and called by `name/1`.

      children = [{BizKit.Cluster.Singleton, CoopSubstrate.Log}]

  Every node supervises a keeper. The first to register the name starts
  the process, linked to itself; the others monitor it, and when it goes
  (its node stopped or became unreachable) race to start it again, so the
  cluster has it again within moments. When a partition heals with one on
  each side, the one on the lower-named node stays and the other stops
  with `{:global_name_conflict, module}`; its keeper then watches the
  survivor.

  The process's state is whatever its `init/1` builds: what it held in
  memory is lost when it moves, as it was on a restart. Calls reach it from
  any node by `name/1`.
  """

  use GenServer

  @doc "How any node calls the one `module`."
  @spec name(module()) :: {:via, module(), module()}
  def name(module), do: {:via, __MODULE__, module}

  # -- :via registration in :global, with our own conflict resolution ----------

  @doc false
  def register_name(module, pid),
    do: if(:global.register_name(module, pid, &resolve/3) == :yes, do: :yes, else: :no)

  @doc false
  def unregister_name(module), do: :global.unregister_name(module)

  @doc false
  def whereis_name(module), do: :global.whereis_name(module)

  @doc false
  def send(module, message), do: :global.send(module, message)

  # Deterministic, so both sides of a healed partition agree on the survivor.
  defp resolve(module, a, b) do
    [keep, stop] = Enum.sort_by([a, b], &node/1)
    Process.exit(stop, {:global_name_conflict, module})
    keep
  end

  def child_spec({module, arg}),
    do: %{id: module, start: {__MODULE__, :start_link, [{module, arg}]}, shutdown: 10_000}

  def child_spec(module) when is_atom(module), do: child_spec({module, []})

  def start_link({module, arg}), do: GenServer.start_link(__MODULE__, {module, arg})

  @impl true
  def init({module, arg}) do
    Process.flag(:trap_exit, true)
    {:ok, claim(%{module: module, arg: arg, local: nil, watching: nil})}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{watching: ref} = s) do
    # Spread the nodes' attempts; :global settles any that still collide.
    Process.send_after(self(), :claim, :rand.uniform(50))
    {:noreply, %{s | watching: nil}}
  end

  def handle_info(:claim, s), do: {:noreply, claim(s)}

  # A healed partition: :global stopped ours in favour of the other's.
  def handle_info({:EXIT, pid, {:global_name_conflict, _}}, %{local: pid} = s),
    do: {:noreply, claim(%{s | local: nil})}

  def handle_info({:EXIT, pid, reason}, %{local: pid} = s), do: {:stop, reason, %{s | local: nil}}
  def handle_info(_other, s), do: {:noreply, s}

  # Stop ours and wait until the name is free, so a restart can claim it.
  @impl true
  def terminate(_reason, %{local: pid, module: module}) when is_pid(pid) do
    Process.exit(pid, :shutdown)

    receive do
      {:EXIT, ^pid, _} -> :ok
    after
      5_000 -> Process.exit(pid, :kill)
    end

    wait_unregistered(module, pid)
  end

  def terminate(_reason, _s), do: :ok

  defp claim(s) do
    case GenServer.start_link(s.module, s.arg, name: name(s.module)) do
      {:ok, pid} ->
        %{s | local: pid, watching: nil}

      {:error, {:already_started, pid}} ->
        %{s | local: nil, watching: Process.monitor(pid)}

      {:error, reason} ->
        exit(reason)
    end
  end

  defp wait_unregistered(module, pid) do
    if :global.whereis_name(module) == pid do
      Process.sleep(1)
      wait_unregistered(module, pid)
    else
      :ok
    end
  end
end
