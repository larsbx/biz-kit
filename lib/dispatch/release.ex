defmodule Dispatch.Release do
  @moduledoc """
  Release tasks for the production OTP image.

  Section 22 forbids auto-migration on boot, so migrating is an explicit
  operator step invoked through this module:

      bin/dispatch eval "Dispatch.Release.migrate()"

  The application is deliberately not started for these tasks. Only the
  repository is, so a migration cannot be blocked by an endpoint that will not
  bind or by a configuration violation in an unrelated subsystem.
  """

  @app :dispatch

  @doc "Applies all pending migrations."
  @spec migrate() :: :ok
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc """
  Rolls one repository back to `version`.

  Section 22 treats a schema change as forward-only in the ordinary case; this
  exists for an incident, not for a routine undo. See docs/runbooks/migrations.md.
  """
  @spec rollback(module(), non_neg_integer()) :: :ok
  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
    :ok
  end

  @doc """
  Reports pending migrations without applying any.

  `/health/ready` reports the same state; this is the form an operator can run
  before a deployment.
  """
  @spec migration_status() :: [{atom(), integer(), String.t()}]
  def migration_status do
    load_app()
    Enum.flat_map(repos(), &Ecto.Migrator.migrations/1)
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  # `Application.load/1` returns `{:error, {:already_loaded, _}}` when the
  # release has started the application, which is normal for `bin/dispatch eval`.
  # Any other error is a genuine failure and must not be swallowed.
  defp load_app do
    case Application.load(@app) do
      :ok -> :ok
      {:error, {:already_loaded, @app}} -> :ok
      {:error, reason} -> raise "could not load #{@app}: #{inspect(reason)}"
    end
  end
end
