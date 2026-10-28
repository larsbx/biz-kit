defmodule FederationService.Worker do
  @moduledoc "Serial bounded inbox/outbox worker; journal retains pending work across failures."
  use GenServer
  def start_link(config), do: GenServer.start_link(__MODULE__, config)

  def init(config) do
    send(self(), :tick)
    {:ok, config}
  end

  def handle_info(:tick, config) do
    FederationService.Inbox.drain(config)
    FederationService.deliver(config)
    FederationService.deliver_subscriptions(config)
    FederationService.refresh(config)
    Process.send_after(self(), :tick, 1000)
    {:noreply, config}
  end
end
