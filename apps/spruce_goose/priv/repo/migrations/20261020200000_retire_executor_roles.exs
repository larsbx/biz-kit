defmodule SpruceGoose.Repo.Migrations.RetireExecutorRoles do
  @moduledoc """
  The derivation and deployment domains are retired, and with them the
  `derivation_executor` and `deployment_executor` roles
  (docs/architecture/2026-10-20-sprucegoose-salvage.md). Grants of those
  roles, which Genesis gave every first actor, would no longer load as a
  `SpruceGoose.Actors.Role`, so they are removed. They confer nothing that
  still exists, and there is no way back to them.
  """
  use Ecto.Migration

  def up do
    execute(
      "DELETE FROM actor_grants WHERE role IN ('derivation_executor', 'deployment_executor')"
    )
  end

  def down, do: :ok
end
