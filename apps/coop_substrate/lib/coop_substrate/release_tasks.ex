defmodule CoopSubstrate.ReleaseTasks do
  @moduledoc """
  Release steps for the ledger, shared by every release that carries it
  (docs/deploy.md). Run explicitly by an operator, never on boot.
  """

  @event_stores [CoopSubstrate.EventStore, CoopSubstrate.Records]

  @doc """
  Create the ledger's event store database if it is missing and initialize
  both stores. Idempotent: an existing database or schema is left as is. Only
  Postgrex starts; no application does.
  """
  @spec init_event_stores() :: :ok
  def init_event_stores do
    Application.load(:coop_substrate)
    {:ok, _} = Application.ensure_all_started(:postgrex)

    for store <- @event_stores do
      config = EventStore.Config.parsed(store, :coop_substrate)
      # Each raises on failure.
      EventStore.Tasks.Create.exec(config, quiet: true)
      EventStore.Tasks.Init.exec(config, quiet: true)
    end

    :ok
  end
end
