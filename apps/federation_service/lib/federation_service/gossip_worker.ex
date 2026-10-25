defmodule FederationService.GossipWorker do
  @moduledoc "Event-driven local port adapter; durable current publications repair lossy gossip."
  use GenServer
  alias FederationService.{Gossip, GossipSync, Store}
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  def address(worker), do: GenServer.call(worker, :address)

  def init(opts) do
    config = Keyword.fetch!(opts, :config)
    store = GenServer.whereis(config.service.store)

    case Store.call(store, :claim_gossip_worker) do
      :ok -> start_port(opts, config, store)
      {:error, reason} -> {:stop, reason}
    end
  end

  defp start_port(opts, config, store) do
    :ok = Store.call(store, :subscribe)
    monitor = Process.monitor(store)

    port =
      Port.open({:spawn_executable, Keyword.fetch!(opts, :executable)}, [
        :binary,
        :exit_status,
        :use_stdio,
        {:line, 90_000}
      ])

    command = %{
      key_file: Keyword.fetch!(opts, :key_file),
      topic: Gossip.topic(config),
      bind: Keyword.get(opts, :bind, "127.0.0.1:0"),
      peers: Keyword.get(opts, :peers, []),
      allowed_endpoints: Keyword.fetch!(opts, :allowed_endpoints)
    }

    true = Port.command(port, Jason.encode!(command) <> "\n")
    Process.send_after(self(), :startup_timeout, 10_000)
    Process.send_after(self(), :anti_entropy, 30_000)

    {:ok,
     %{
       config: config,
       port: port,
       store: store,
       monitor: monitor,
       address: nil,
       pending: MapSet.new(),
       scheduled: false,
       force: false
     }}
  end

  def format_status(%{state: %{config: config} = state} = status) do
    config =
      config
      |> Map.put(:seed, :redacted)
      |> Map.update!(:service, &Map.put(&1, :private_key, :redacted))

    %{status | state: %{state | config: config}}
  end

  def format_status(status), do: status

  def handle_call(:address, _, state), do: {:reply, state.address, state}

  def handle_info({:discovery_committed, store}, %{store: store} = state) do
    :ok = Store.call(store, :notifications_received)
    {:noreply, schedule(state)}
  end

  def handle_info(:work, state) do
    state = %{state | scheduled: false}

    if state.address != nil do
      Gossip.drain(state.config)
      GossipSync.drain(state.config)

      frames =
        GossipSync.frames(state.config, System.system_time(:second), state.pending) ++
          Gossip.frames(state.config, System.system_time(:second), state.pending, state.force)

      pending =
        frames
        |> Enum.take(16 - MapSet.size(state.pending))
        |> Enum.reduce(state.pending, fn {id, wire}, pending ->
          sync = String.starts_with?(id, "sync:")
          now = System.system_time(:second)

          current =
            if sync,
              do: GossipSync.current?(state.config, id, now),
              else: Gossip.current?(state.config, id)

          {rate, limit} = if sync, do: {:gossip_sync_outgoing, 4}, else: {:gossip_outgoing, 12}

          if current and
               Store.call(state.store, {:rate, rate, limit, now}) ==
                 :ok do
            true =
              Port.command(
                state.port,
                Jason.encode!(%{op: "broadcast", id: id, body: Base.encode64(wire)}) <> "\n"
              )

            MapSet.put(pending, id)
          else
            pending
          end
        end)

      {:noreply, %{state | pending: pending, force: false}}
    else
      {:noreply, state}
    end
  end

  def handle_info(:anti_entropy, state) do
    Process.send_after(self(), :anti_entropy, 30_000)
    {:noreply, schedule(state)}
  end

  def handle_info(:startup_timeout, %{address: nil} = state),
    do: {:stop, :sidecar_start_timeout, state}

  def handle_info(:startup_timeout, state), do: {:noreply, state}

  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    with {:ok, message} <- Jason.decode(line) do
      event(message, state)
    else
      _ -> {:stop, :invalid_sidecar_output, state}
    end
  end

  def handle_info({port, {:data, {:noeol, _}}}, %{port: port} = state),
    do: {:stop, :sidecar_line_limit, state}

  def handle_info({port, {:exit_status, code}}, %{port: port} = state),
    do: {:stop, {:sidecar_exit, code}, state}

  def handle_info({:DOWN, ref, :process, _, reason}, %{monitor: ref} = state),
    do: {:stop, {:store_exit, reason}, state}

  defp event(%{"event" => "ready", "address" => address}, state) do
    # The endpoint in the address must agree with the locally configured key.
    if address["id"] == state.config.publisher do
      {:noreply, schedule(%{state | address: address})}
    else
      {:stop, :endpoint_key_mismatch, state}
    end
  end

  defp event(%{"event" => "message", "body" => body}, state) do
    with {:ok, wire} <- Base.decode64(body) do
      case GossipSync.receive_event(state.config, wire) do
        :not_sync -> Gossip.receive_event(state.config, wire)
        _ -> :ok
      end
    end

    {:noreply, schedule(state)}
  end

  defp event(%{"event" => "broadcast_queued", "id" => id}, state) do
    if MapSet.member?(state.pending, id) do
      :ok =
        if String.starts_with?(id, "sync:") do
          GossipSync.sent(state.config, id, System.system_time(:second))
        else
          Store.call(
            state.store,
            {:gossip_sent, Gossip.topic(state.config), id, System.system_time(:second)}
          )
        end

      {:noreply, schedule(%{state | pending: MapSet.delete(state.pending, id)})}
    else
      {:stop, :unexpected_sidecar_receipt, state}
    end
  end

  defp event(%{"event" => "neighbor_up"}, state), do: {:noreply, schedule(%{state | force: true})}

  defp event(%{"event" => event}, state) when event in ["neighbor_down", "lagged"],
    do: {:noreply, state}

  defp event(_, state), do: {:stop, :invalid_sidecar_event, state}
  defp schedule(%{scheduled: true} = state), do: state

  defp schedule(state) do
    send(self(), :work)
    %{state | scheduled: true}
  end

  def terminate(_, state) do
    if Port.info(state.port), do: Port.close(state.port)
  end
end
