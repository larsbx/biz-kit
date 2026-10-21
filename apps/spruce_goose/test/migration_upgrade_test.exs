defmodule SpruceGoose.MigrationUpgradeRepo do
  use Ecto.Repo,
    otp_app: :spruce_goose,
    adapter: Ecto.Adapters.Postgres
end

defmodule SpruceGoose.MigrationUpgradeTest do
  use ExUnit.Case, async: false

  alias SpruceGoose.MigrationUpgradeRepo, as: UpgradeRepo

  @migrations Path.expand("../priv/repo/migrations", __DIR__)
  @grant_history_version 20_261_021_100_000
  @grant_history_migration SpruceGoose.Repo.Migrations.PreserveActorGrantHistory

  test "grant-history upgrade preserves authority, protects old writers and refuses lossy rollback" do
    database = "sprucegoose_grants_upgrade_#{System.unique_integer([:positive])}"

    config =
      SpruceGoose.Repo.config()
      |> Keyword.drop([:name, :pool, :pool_size])
      |> Keyword.put(:database, database)
      |> Keyword.put(:pool_size, 2)

    assert :ok = Ecto.Adapters.Postgres.storage_up(config)

    on_exit(fn ->
      if pid = Process.whereis(UpgradeRepo), do: GenServer.stop(pid)
      Ecto.Adapters.Postgres.storage_down(config)
    end)

    {:ok, _pid} = UpgradeRepo.start_link(config)
    Ecto.Migrator.run(UpgradeRepo, @migrations, :up, to: 20_261_020_200_000)
    sql = &Ecto.Adapters.SQL.query!(UpgradeRepo, &1, [])

    %{rows: [[actor_id]]} =
      sql.("""
      INSERT INTO actors (name, kind, created_by)
      VALUES ('upgrade-admin', 'human', 'genesis') RETURNING id
      """)

    %{rows: [[grant_id, granted_at]]} =
      sql.("""
      INSERT INTO actor_grants (actor_id, role, scope, granted_by, granted_at)
      SELECT id, 'admin', '*', 'genesis', now() AT TIME ZONE 'utc'
      FROM actors WHERE name = 'upgrade-admin' RETURNING id, granted_at
      """)

    Ecto.Migrator.run(UpgradeRepo, @migrations, :up, all: true)
    assert [] == Ecto.Migrator.run(UpgradeRepo, @migrations, :up, all: true)

    assert %{rows: [[^grant_id, ^actor_id, "admin", "*", "genesis", ^granted_at, nil, nil]]} =
             sql.(
               "SELECT id, actor_id, role, scope, granted_by, granted_at, revoked_at, revoked_by FROM actor_grants"
             )

    # Target D7 explicitly: later retirement migrations may follow it.
    # An all-active database can safely roll back and forward before adoption.
    Ecto.Migrator.down(UpgradeRepo, @grant_history_version, @grant_history_migration)
    Ecto.Migrator.run(UpgradeRepo, @migrations, :up, all: true)
    assert_raise Postgrex.Error, fn -> sql.("DELETE FROM actor_grants") end

    assert_raise Postgrex.Error, fn ->
      sql.(
        "INSERT INTO actor_grants (actor_id, role, scope, granted_by, granted_at) SELECT actor_id, role, scope, 'duplicate', granted_at FROM actor_grants"
      )
    end

    sql.(
      "UPDATE actor_grants SET revoked_at = now() AT TIME ZONE 'utc', revoked_by = 'upgrade-admin'"
    )

    sql.(
      "INSERT INTO actor_grants (actor_id, role, scope, granted_by, granted_at) SELECT actor_id, role, scope, 'upgrade-admin', now() AT TIME ZONE 'utc' FROM actor_grants"
    )

    assert %{rows: [[2, 1]]} =
             sql.("SELECT count(*), count(*) FILTER (WHERE revoked_at IS NULL) FROM actor_grants")

    assert_raise Postgrex.Error, ~r/cannot downgrade actor grants/, fn ->
      Ecto.Migrator.down(UpgradeRepo, @grant_history_version, @grant_history_migration)
    end

    # The failed migration is transactional: history and the guard still stand.
    assert %{rows: [[2, 1]]} =
             sql.("SELECT count(*), count(*) FILTER (WHERE revoked_at IS NULL) FROM actor_grants")

    assert_raise Postgrex.Error, fn -> sql.("DELETE FROM actor_grants") end
    assert [] == Ecto.Migrator.run(UpgradeRepo, @migrations, :up, all: true)
    GenServer.stop(UpgradeRepo)
  end

  test "hierarchy migration backfills a workflow created under the prior schema" do
    database = "sprucegoose_upgrade_#{System.unique_integer([:positive])}"

    config =
      SpruceGoose.Repo.config()
      |> Keyword.drop([:name, :pool, :pool_size])
      |> Keyword.put(:database, database)
      |> Keyword.put(:pool_size, 2)

    assert :ok = Ecto.Adapters.Postgres.storage_up(config)

    on_exit(fn ->
      if pid = Process.whereis(UpgradeRepo), do: GenServer.stop(pid)
      Ecto.Adapters.Postgres.storage_down(config)
    end)

    {:ok, _pid} = UpgradeRepo.start_link(config)

    Ecto.Migrator.run(UpgradeRepo, @migrations, :up, to: 20_260_727_002_051)

    Ecto.Adapters.SQL.query!(
      UpgradeRepo,
      """
      INSERT INTO workflows (workflow_id, definition)
      VALUES ('preexisting', '{"schema_version":1,"tasks":[{"id":"a","kind":"oban"}]}')
      """
    )

    Ecto.Migrator.run(UpgradeRepo, @migrations, :up, all: true)

    assert %{rows: [["preexisting", "preexisting", "legacy-import"]]} =
             Ecto.Adapters.SQL.query!(
               UpgradeRepo,
               """
               SELECT workflows.workflow_id, workflows.name, roadmaps.key
               FROM workflows
               JOIN roadmaps ON roadmaps.id = workflows.roadmap_id
               WHERE workflows.workflow_id = 'preexisting'
               """
             )

    # Round-trip the tail of the migration set. The property-graph assertions
    # that used to sit here were retired with the object itself (see
    # `20260908000000_drop_task_dependency_property_graph`); what this still
    # proves is that the backfilled hierarchy survives a down/up cycle.
    Ecto.Migrator.run(UpgradeRepo, @migrations, :down, to: 20_260_810_133_000)
    Ecto.Migrator.run(UpgradeRepo, @migrations, :up, all: true)

    assert %{rows: [["preexisting", "preexisting", "legacy-import"]]} =
             Ecto.Adapters.SQL.query!(
               UpgradeRepo,
               """
               SELECT workflows.workflow_id, workflows.name, roadmaps.key
               FROM workflows
               JOIN roadmaps ON roadmaps.id = workflows.roadmap_id
               WHERE workflows.workflow_id = 'preexisting'
               """
             )

    GenServer.stop(UpgradeRepo)
  end
end
