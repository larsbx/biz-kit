defmodule Eatsbot.Repo.Migrations.DependencySecurity do
  @moduledoc """
  Uses the JTI as the token resource's sole primary key.

  Duplicate JTIs are ambiguous credentials: consolidate them as revocations,
  preserving the longest expiry. Unique credentials retain their state.
  Consolidation is irreversible; rollback restores the schema, not removed rows.
  """

  use Ecto.Migration

  def up do
    execute("LOCK TABLE tokens IN ACCESS EXCLUSIVE MODE")
    execute(token_consolidation_sql())

    drop constraint("tokens", "tokens_pkey")

    execute("ALTER TABLE \"tokens\" ADD PRIMARY KEY (jti)")

    alter table(:tokens) do
      remove :id
    end
  end

  @doc false
  def token_consolidation_sql do
    """
    WITH duplicates AS (
      SELECT jti, MAX(expires_at) AS expires_at
      FROM tokens
      GROUP BY jti
      HAVING COUNT(*) > 1
    ), keepers AS (
      SELECT DISTINCT ON (tokens.jti) tokens.id, tokens.jti
      FROM tokens
      JOIN duplicates USING (jti)
      ORDER BY tokens.jti, (tokens.purpose = 'revocation') DESC,
               tokens.expires_at DESC, tokens.id
    ), revoked AS (
      UPDATE tokens
      SET purpose = 'revocation', expires_at = duplicates.expires_at
      FROM keepers
      JOIN duplicates USING (jti)
      WHERE tokens.id = keepers.id AND tokens.jti = keepers.jti
      RETURNING tokens.id, tokens.jti
    )
    DELETE FROM tokens
    USING revoked
    WHERE tokens.jti = revoked.jti AND tokens.id <> revoked.id
    """
  end

  def down do
    alter table(:tokens) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()")
    end

    execute("ALTER TABLE \"tokens\" DROP constraint tokens_pkey")

    execute("ALTER TABLE \"tokens\" ADD PRIMARY KEY (id, jti)")
  end
end
