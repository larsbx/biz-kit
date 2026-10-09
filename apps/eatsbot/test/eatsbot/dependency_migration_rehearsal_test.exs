defmodule Eatsbot.DependencyMigrationRehearsalTest do
  use ExUnit.Case, async: false

  alias AshAuthentication.{Jwt, TokenResource.Actions}
  alias Eatsbot.Accounts.{Token, User}
  alias Eatsbot.Repo

  @security_version 20_261_009_114_507

  setup do
    # A separate database exercises the actual Ecto transaction and primary key.
    # Never retarget the application's database or run a down migration there.
    config =
      Repo.config()
      |> Keyword.delete(:url)
      |> Keyword.merge(
        database: "eatsbot_migration_rehearsal_#{System.unique_integer([:positive])}",
        name: nil,
        pool: DBConnection.ConnectionPool,
        pool_size: 3
      )

    assert :ok = Ecto.Adapters.Postgres.storage_up(config)
    {:ok, pid} = Repo.start_link(config)
    Process.unlink(pid)
    previous_repo = Repo.put_dynamic_repo(pid)

    on_exit(fn ->
      Supervisor.stop(pid)
      assert :ok = Ecto.Adapters.Postgres.storage_down(config)
    end)

    Ecto.Migrator.run(Repo, :up, to: @security_version - 2, log: false)
    {:ok, previous_repo: previous_repo}
  end

  test "populated old schema rolls forward, back, and forward without reviving credentials", %{
    previous_repo: previous_repo
  } do
    try do
      user = Ash.create!(User, %{email: "migration-rehearsal@example.com"}, authorize?: false)

      {valid, valid_claims} = signed_token(user)
      {duplicate, duplicate_claims} = signed_token(user)
      {revoked, revoked_claims} = signed_token(user)

      insert_token(valid_claims, "user")
      insert_token(duplicate_claims, "user")
      insert_token(duplicate_claims, "revocation", duplicate_claims["exp"] + 3_600)
      insert_token(revoked_claims, "revocation")

      # A duplicated UUID across distinct JTIs is legal under the old composite key.
      id = Ash.UUID.generate()
      claims = Map.put(duplicate_claims, "jti", "cross-subject")
      insert_token(claims, "user", claims["exp"], id)
      insert_token(Map.put(claims, "sub", "user?id=other"), "magic_link", claims["exp"] + 7_200)
      insert_token(Map.put(claims, "jti", "shared-uuid"), "reset", claims["exp"], id)

      insert_legacy_price()
      original = token_rows()

      # A live reader must make migration fail safely rather than block forever.
      dynamic_repo = Repo.get_dynamic_repo()
      parent = self()

      blocker =
        Task.async(fn ->
          Repo.put_dynamic_repo(dynamic_repo)

          Repo.transaction(fn ->
            query("LOCK TABLE tokens IN ACCESS SHARE MODE")
            send(parent, :tokens_locked)

            receive do
              :release -> :ok
            end
          end)
        end)

      assert_receive :tokens_locked, 5_000

      try do
        assert_raise Postgrex.Error, ~r/lock timeout/, fn ->
          Ecto.Migrator.run(Repo, :up, all: true, log: false)
        end
      after
        send(blocker.pid, :release)
        assert {:ok, :ok} = Task.await(blocker)
      end

      assert token_rows() == original
      assert primary_key() == ["id", "jti"]

      # Consolidation succeeds, then an external reference blocks the key DDL.
      # This tests Ecto's transaction across statements, not just CTE atomicity.
      query("""
      CREATE TABLE rehearsal_token_refs (
        token_id uuid, jti text,
        FOREIGN KEY (token_id, jti) REFERENCES tokens (id, jti)
      )
      """)

      query("INSERT INTO rehearsal_token_refs SELECT id, jti FROM tokens WHERE jti = $1", [
        valid_claims["jti"]
      ])

      assert_raise Postgrex.Error, ~r/other objects depend/, fn ->
        Ecto.Migrator.run(Repo, :up, all: true, log: false)
      end

      assert token_rows() == original
      assert primary_key() == ["id", "jti"]
      query("DROP TABLE rehearsal_token_refs")

      Ecto.Migrator.run(Repo, :up, all: true, log: false)
      assert primary_key() == ["jti"]
      refute id_column?()
      assert bearer(valid).assigns.current_user.id == user.id
      refute bearer(duplicate).assigns[:current_user]
      refute bearer(revoked).assigns[:current_user]

      assert :error =
               AshAuthentication.Plug.Helpers.authenticate_resource_from_session(
                 User,
                 %{"user_token" => duplicate},
                 :eatsbot,
                 []
               )

      assert Actions.jti_revoked?(Token, duplicate_claims["jti"])
      assert Actions.jti_revoked?(Token, "cross-subject")

      assert query(
               "SELECT purpose, EXTRACT(EPOCH FROM expires_at)::bigint FROM tokens WHERE jti = $1",
               [duplicate_claims["jti"]]
             ).rows ==
               [["revocation", duplicate_claims["exp"] + 3_600]]

      assert query("SELECT purpose FROM tokens WHERE jti = 'shared-uuid'").rows == [["reset"]]
      assert query("SELECT COUNT(*) FROM tokens").rows == [[5]]
      assert_legacy_price()

      {:ok, new_token, _claims} = Jwt.token_for_user(user)
      assert bearer(new_token).assigns.current_user.id == user.id
      assert :ok = Actions.revoke(Token, new_token)
      refute bearer(new_token).assigns[:current_user]

      Ecto.Migrator.run(Repo, :down, to: @security_version, log: false)
      assert primary_key() == ["id", "jti"]
      assert id_column?()
      refute token_rows() == original
      assert query("SELECT COUNT(*) FROM tokens WHERE id IS NULL").rows == [[0]]
      refute bearer(duplicate).assigns[:current_user]

      Ecto.Migrator.run(Repo, :up, all: true, log: false)
      assert primary_key() == ["jti"]
      assert bearer(valid).assigns.current_user.id == user.id
      refute bearer(duplicate).assigns[:current_user]
      refute bearer(new_token).assigns[:current_user]
      assert_legacy_price()
    after
      Repo.put_dynamic_repo(previous_repo)
    end
  end

  defp signed_token(user) do
    {:ok, token, claims} =
      Joken.generate_and_sign(
        Jwt.Config.default_claims(User),
        %{"sub" => AshAuthentication.user_to_subject(user)},
        Jwt.Config.token_signer(User)
      )

    {token, claims}
  end

  defp insert_token(claims, purpose, expires_at \\ nil, id \\ Ash.UUID.generate()) do
    query(
      """
      INSERT INTO tokens (id, jti, subject, expires_at, purpose, extra_data)
      VALUES ($1::text::uuid, $2, $3, to_timestamp($4), $5, '{"fixture":true}'::jsonb)
      """,
      [id, claims["jti"], claims["sub"], expires_at || claims["exp"], purpose]
    )
  end

  defp insert_legacy_price do
    query("""
    INSERT INTO prices (money) VALUES (ROW('USD', 12345678901234567890.123456789)::money_with_currency)
    """)
  end

  defp assert_legacy_price do
    [price] = Ash.read!(EatsbotCore.Products.Price, authorize?: false)
    assert price.money.currency == :USD
    assert Decimal.equal?(price.money.amount, Decimal.new("12345678901234567890.123456789"))
  end

  defp token_rows, do: query("SELECT * FROM tokens ORDER BY jti, id").rows

  defp primary_key do
    query("""
    SELECT a.attname FROM pg_constraint c
    CROSS JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS k(attnum, position)
    JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
    WHERE c.conrelid = 'tokens'::regclass AND c.contype = 'p'
    ORDER BY k.position
    """).rows
    |> List.flatten()
  end

  defp id_column? do
    query(
      "SELECT COUNT(*) FROM information_schema.columns WHERE table_name = 'tokens' AND column_name = 'id' AND table_schema = 'public'"
    ).rows == [[1]]
  end

  defp bearer(token) do
    Plug.Test.conn(:get, "/")
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
    |> AshAuthentication.Plug.Helpers.retrieve_from_bearer(:eatsbot)
  end

  defp query(sql, params \\ []),
    do: Ecto.Adapters.SQL.query!(Repo.get_dynamic_repo(), sql, params)
end
