defmodule SpruceGoose.Repo.Migrations.CreateIdentityNativeSessions do
  @moduledoc """
  Native apps' sessions, kept so a restart does not sign devices out
  (docs/architecture/2026-10-21-native-sign-in.md). The key is the SHA-256 of
  the token; the token itself is never stored.
  """
  use Ecto.Migration

  def change do
    create table(:identity_native_sessions, primary_key: false) do
      add(:token_hash, :binary, primary_key: true)
      add(:principal, :text, null: false)
      add(:issuer, :text, null: false)
      add(:subject, :text, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(index(:identity_native_sessions, [:principal]))
  end
end
