defmodule SpruceGoose.ReleaseTasks do
  @moduledoc """
  Release tasks for a production image, where Mix is absent
  (docs/deploy.md). Migrating is an explicit operator step, never done on
  boot, as for dispatch (`Dispatch.Release`):

      bin/orchestration eval "SpruceGoose.ReleaseTasks.migrate()"

  It initializes the ledger's event stores (creating their database if it
  is missing) and applies SpruceGoose's pending migrations. Each step is
  idempotent, so it is safe to run before every start. Only the
  repositories run: no application starts, so a migration cannot be
  blocked by an endpoint that will not bind or a check in another subsystem.
  """

  @event_stores [CoopSubstrate.EventStore, CoopSubstrate.Records]

  @doc "Initialize the event stores and apply all pending migrations."
  @spec migrate() :: :ok
  def migrate do
    for app <- [:coop_substrate, :spruce_goose], do: Application.load(app)
    {:ok, _} = Application.ensure_all_started(:postgrex)
    {:ok, _} = Application.ensure_all_started(:ecto_sql)

    for store <- @event_stores do
      config = EventStore.Config.parsed(store, :coop_substrate)
      # Each raises on failure; an existing database or schema is left as is.
      EventStore.Tasks.Create.exec(config, quiet: true)
      EventStore.Tasks.Init.exec(config, quiet: true)
    end

    for repo <- Application.fetch_env!(:spruce_goose, :ecto_repos) do
      :ok = created(repo.__adapter__().storage_up(repo.config()))
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  defp created(:ok), do: :ok
  defp created({:error, :already_up}), do: :ok
  defp created({:error, reason}), do: raise("could not create the database: #{inspect(reason)}")
end
