Code.require_file("../../priv/repo/migrations/20261009114507_dependency_security.exs", __DIR__)

defmodule Eatsbot.TokenMigrationDependencyTest do
  use Eatsbot.DataCase, async: false

  alias Eatsbot.Repo.Migrations.DependencySecurity

  test "duplicate JTIs become revocations until their longest expiry while unique tokens survive" do
    query("""
    CREATE TEMP TABLE tokens (
      id uuid NOT NULL,
      jti text NOT NULL,
      subject text NOT NULL,
      expires_at timestamptz NOT NULL,
      purpose text NOT NULL,
      PRIMARY KEY (id, jti)
    ) ON COMMIT DROP
    """)

    insert_token("duplicate", "user", "2030-01-01")
    insert_token("duplicate", "revocation", "2029-01-01")
    insert_token("ambiguous", "user", "2031-01-01")
    insert_token("ambiguous", "user", "2032-01-01")
    insert_token("unique", "user", "2033-01-01")
    insert_token("revoked", "revocation", "2034-01-01")

    query(DependencySecurity.token_consolidation_sql())
    query(DependencySecurity.token_consolidation_sql())
    query("ALTER TABLE tokens DROP CONSTRAINT tokens_pkey")
    query("ALTER TABLE tokens ADD PRIMARY KEY (jti)")
    query("ALTER TABLE tokens DROP COLUMN id")

    assert query("SELECT jti, purpose, expires_at::date::text FROM tokens ORDER BY jti").rows == [
             ["ambiguous", "revocation", "2032-01-01"],
             ["duplicate", "revocation", "2030-01-01"],
             ["revoked", "revocation", "2034-01-01"],
             ["unique", "user", "2033-01-01"]
           ]
  end

  defp insert_token(jti, purpose, expires_at) do
    query(
      "INSERT INTO tokens VALUES ($1::text::uuid, $2, 'user?id=fixture', $3::text::timestamptz, $4)",
      [Ash.UUID.generate(), jti, expires_at, purpose]
    )
  end

  defp query(sql, params \\ []), do: Ecto.Adapters.SQL.query!(Repo, sql, params)
end
