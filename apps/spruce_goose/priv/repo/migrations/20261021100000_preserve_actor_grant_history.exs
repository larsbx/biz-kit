defmodule SpruceGoose.Repo.Migrations.PreserveActorGrantHistory do
  @moduledoc """
  Close legacy grants instead of deleting them while the legacy writer remains.
  Existing grants remain active, with their original identities and provenance.
  The guard also refuses destructive revocation by a pre-upgrade binary.
  """
  use Ecto.Migration

  def up do
    alter table(:actor_grants) do
      add(:revoked_at, :utc_datetime_usec)
      add(:revoked_by, :text)
    end

    drop(
      unique_index(:actor_grants, [:actor_id, :role, :scope],
        name: "actor_grants_unique_grant_index"
      )
    )

    create(
      unique_index(:actor_grants, [:actor_id, :role, :scope],
        name: "actor_grants_unique_grant_index",
        where: "revoked_at IS NULL"
      )
    )

    create(
      constraint(:actor_grants, :actor_grants_revocation_pair,
        check:
          "(revoked_at IS NULL AND revoked_by IS NULL) OR " <>
            "(revoked_at IS NOT NULL AND revoked_by IS NOT NULL AND " <>
            "length(trim(revoked_by)) > 0 AND revoked_at >= granted_at)"
      )
    )

    execute("""
    CREATE FUNCTION preserve_actor_grant_history() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'actor grant history cannot be deleted; close the grant instead';
      END IF;
      IF OLD.revoked_at IS NOT NULL OR NEW.revoked_at IS NULL OR
         ROW(NEW.id, NEW.actor_id, NEW.role, NEW.scope, NEW.granted_by,
             NEW.granted_at, NEW.inserted_at) IS DISTINCT FROM
         ROW(OLD.id, OLD.actor_id, OLD.role, OLD.scope, OLD.granted_by,
             OLD.granted_at, OLD.inserted_at) THEN
        RAISE EXCEPTION 'actor grants are immutable except for one revocation';
      END IF;
      RETURN NEW;
    END
    $$
    """)

    execute("""
    CREATE TRIGGER preserve_actor_grant_history
    BEFORE UPDATE OR DELETE ON actor_grants
    FOR EACH ROW EXECUTE FUNCTION preserve_actor_grant_history()
    """)
  end

  def down do
    # A downgrade must never discard revocations or reactivate old authority.
    execute("LOCK TABLE actor_grants IN ACCESS EXCLUSIVE MODE")

    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM actor_grants WHERE revoked_at IS NOT NULL) THEN
        RAISE EXCEPTION 'cannot downgrade actor grants after revocation; retain history and roll forward';
      END IF;
    END $$
    """)

    execute("DROP TRIGGER preserve_actor_grant_history ON actor_grants")
    execute("DROP FUNCTION preserve_actor_grant_history()")
    drop(constraint(:actor_grants, :actor_grants_revocation_pair))

    drop(
      unique_index(:actor_grants, [:actor_id, :role, :scope],
        name: "actor_grants_unique_grant_index"
      )
    )

    create(
      unique_index(:actor_grants, [:actor_id, :role, :scope],
        name: "actor_grants_unique_grant_index"
      )
    )

    alter table(:actor_grants) do
      remove(:revoked_by)
      remove(:revoked_at)
    end
  end
end
