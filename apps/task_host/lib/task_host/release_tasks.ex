defmodule TaskHost.ReleaseTasks do
  @moduledoc """
  Release tasks where Mix is absent (docs/deploy.md). Migrating is an explicit
  operator step before each start, never done on boot:

      bin/orchestration eval "TaskHost.ReleaseTasks.migrate()"

  It initializes the ledger's event stores (creating their database if it is
  missing) and applies the host's migrations (native sessions). Each step is
  idempotent. Only the repositories run: no application starts.
  """

  @doc "Initialize the event stores and apply the host's pending migrations."
  @spec migrate() :: :ok
  def migrate do
    for app <- [:coop_substrate, :task_host], do: Application.load(app)
    {:ok, _} = Application.ensure_all_started(:postgrex)
    {:ok, _} = Application.ensure_all_started(:ecto_sql)

    :ok = CoopSubstrate.ReleaseTasks.init_event_stores()

    for repo <- Application.fetch_env!(:task_host, :ecto_repos) do
      :ok = created(repo.__adapter__().storage_up(repo.config()))
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  defp created(:ok), do: :ok
  defp created({:error, :already_up}), do: :ok
  defp created({:error, reason}), do: raise("could not create the database: #{inspect(reason)}")
end
