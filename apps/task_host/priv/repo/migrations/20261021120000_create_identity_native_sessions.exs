defmodule TaskHost.Repo.Migrations.CreateIdentityNativeSessions do
  @moduledoc """
  Native apps' sessions, kept so a restart does not sign devices out
  (docs/architecture/2026-10-21-native-sign-in.md). The key is the SHA-256 of
  the token; the token itself is never stored.

  The same version as SpruceGoose's migration that created the table: on the
  database SpruceGoose used, it is already recorded as run, and the rows stay
  (docs/architecture/2026-11-09-task-host.md).
  """
  use Ecto.Migration

  def change do
    create_if_not_exists table(:identity_native_sessions, primary_key: false) do
      add(:token_hash, :binary, primary_key: true)
      add(:principal, :text, null: false)
      add(:issuer, :text, null: false)
      add(:subject, :text, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create_if_not_exists(index(:identity_native_sessions, [:principal]))
  end
end
