defmodule CoopSubstrate.HistoryArchiveRestoreTest do
  use ExUnit.Case, async: false

  alias CoopSubstrate.{HistoryArchive, HistoryArchiveFixture, LegacyDb}
  alias CoopSubstrate.HistoryArchive.Preflight

  # This acceptance uses a disposable PostgreSQL database and real binary COPY,
  # but no LogCase, governance record, application signer, or writer fence.
  # The schemas exercise retained data types; they are not a production dump.
  @schemas [
    {"actor_grants",
     "id bigint PRIMARY KEY, actor_id text NOT NULL, role text NOT NULL, " <>
       "closed_at timestamptz, grant_history jsonb NOT NULL"},
    {"certified_events",
     "id bigint PRIMARY KEY, event_id text NOT NULL, etf bytea NOT NULL, at timestamptz"},
    {"notes", "id bigint PRIMARY KEY, body text, meta jsonb, attachment bytea"},
    {"events", "id bigint PRIMARY KEY, event_type text NOT NULL, payload jsonb, at timestamp(6)"},
    {"ledger_import_receipts",
     "id bigint PRIMARY KEY, legacy_id text NOT NULL, manifest_digest bytea, payload jsonb"},
    {"grandfathered_baselines",
     "id bigint PRIMARY KEY, canonical_bytes bytea NOT NULL, metadata jsonb"},
    {"outbox_events",
     "id uuid PRIMARY KEY, event_key text NOT NULL UNIQUE, aggregate_type text NOT NULL, " <>
       "aggregate_id text NOT NULL, event_type text NOT NULL, payload jsonb NOT NULL, " <>
       "status text NOT NULL, attempts integer NOT NULL, available_at timestamp(6) NOT NULL, " <>
       "dispatched_at timestamp(6), last_error text, inserted_at timestamp(6) NOT NULL, " <>
       "updated_at timestamp(6) NOT NULL"}
  ]

  setup do
    {conn, opts} = LegacyDb.create!("history_restore")
    root = Path.join(System.tmp_dir!(), "history-restore-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    for {table, columns} <- @schemas do
      Postgrex.query!(conn, "CREATE TABLE public.#{table} (#{columns})", [])
    end

    seed!(conn)

    %{
      conn: conn,
      opts: opts,
      dir: Path.join(root, "archive"),
      files: HistoryArchiveFixture.provenance_files!(root)
    }
  end

  test "all seven tables restore every retained field including the complete outbox", c do
    expected = Map.new(@schemas, fn {name, _} -> {name, rows(c.conn, name)} end)

    assert {:error, {:undispatched_outbox, 2}} =
             HistoryArchive.export("spruce_goose", c.opts, c.dir, files: c.files)

    refute File.exists?(c.dir)

    assert {:ok, %{manifest_sha256: digest, tables: 7}} =
             HistoryArchive.export("spruce_goose", c.opts, c.dir,
               files: c.files,
               allow_undispatched_outbox: true
             )

    assert {:ok, %{manifest_sha256: ^digest, outbox_undispatched: 2}} =
             Preflight.verify(c.dir, "spruce_goose", digest)

    manifest = c.dir |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()
    by_name = Map.new(manifest["tables"], &{&1["name"], &1})

    assert Enum.sort(Map.keys(by_name)) == Enum.sort(HistoryArchive.spec("spruce_goose").tables)
    assert manifest["outbox"] == %{"table" => "outbox_events", "undispatched" => 2}

    for {name, _columns} <- @schemas do
      table = by_name[name]
      assert table["absent"] == false
      assert table["rows"] == length(expected[name])

      Postgrex.query!(
        c.conn,
        "CREATE TABLE public.restored_#{name} (LIKE public.#{name} INCLUDING ALL)",
        []
      )

      archive_file = Path.join(c.dir, table["file"])

      assert {:ok, _} =
               Postgrex.transaction(c.conn, fn conn ->
                 archive_file
                 |> File.stream!(65_536)
                 |> Enum.into(
                   Postgrex.stream(
                     conn,
                     "COPY public.restored_#{name} FROM STDIN (FORMAT binary)",
                     []
                   )
                 )
               end)

      assert rows(c.conn, "restored_#{name}") == expected[name],
             "restored #{name} lost or changed retained fields"

      assert rows(c.conn, name) == expected[name], "export changed source #{name}"
    end

    assert [["dispatched", false, 1], ["pending", true, 0], ["failed", true, 20]] ==
             Postgrex.query!(
               c.conn,
               "SELECT status, dispatched_at IS NULL, attempts " <>
                 "FROM public.restored_outbox_events ORDER BY id",
               []
             ).rows

    assert {:ok, %{manifest_sha256: ^digest, outbox_undispatched: 2}} =
             Preflight.verify(c.dir, "spruce_goose", digest)
  end

  defp rows(conn, name),
    do: Postgrex.query!(conn, "SELECT * FROM public.#{name} ORDER BY id", []).rows

  defp seed!(conn) do
    for sql <- [
          "INSERT INTO actor_grants VALUES " <>
            "(1, 'actor-1', 'operator', NULL, '[{\"kind\":\"opened\",\"scope\":\"p-1\"}]'), " <>
            "(2, 'actor-2', 'reviewer', '2026-11-01T10:00:00.123456Z', " <>
            "'[{\"kind\":\"opened\"},{\"kind\":\"closed\",\"reason\":\"retired\"}]')",
          "INSERT INTO notes VALUES " <>
            "(1, 'retained — note', '{\"nested\":[1,true,null,\"value\"]}', decode('00ff83', 'hex')), " <>
            "(2, NULL, NULL, decode('', 'hex'))",
          "INSERT INTO events VALUES " <>
            "(1, 'task.changed', '{\"task_id\":\"t-1\",\"version\":3}', '2026-11-02 10:00:00.654321'), " <>
            "(2, 'legacy.audit', NULL, NULL)",
          "INSERT INTO ledger_import_receipts VALUES " <>
            "(1, 'legacy-1', decode(repeat('ab',32), 'hex'), '{\"accepted\":true}'), " <>
            "(2, 'legacy-2', NULL, '{\"accepted\":false,\"reason\":\"already present\"}')",
          "INSERT INTO grandfathered_baselines VALUES " <>
            "(1, decode('83ff0001', 'hex'), '{\"source\":\"baseline-1\",\"ids\":[1,2]}'), " <>
            "(2, decode('', 'hex'), NULL)"
        ] do
      Postgrex.query!(conn, sql, [])
    end

    Postgrex.query!(
      conn,
      "INSERT INTO certified_events VALUES " <>
        "(1, 'cert-1', $1, '2026-11-03T12:34:56.123456Z'), (2, 'cert-2', $2, NULL)",
      [:erlang.term_to_binary({:retained, 123, <<0, 255>>}), <<0, 255, 131, 0>>]
    )

    for {suffix, status, attempts, dispatched, error} <- [
          {1, "dispatched", 1, "'2026-11-04 10:01:00.000001'", "NULL"},
          {2, "pending", 0, "NULL", "NULL"},
          {3, "failed", 20, "NULL", "'delivery timeout; reconcile externally'"}
        ] do
      Postgrex.query!(
        conn,
        "INSERT INTO outbox_events VALUES (" <>
          "'00000000-0000-0000-0000-00000000000#{suffix}', " <>
          "'task:t-#{suffix}:1:0', 'task', 't-#{suffix}', 'task.changed', " <>
          "'{\"task_id\":\"t-#{suffix}\",\"bytes_hex\":\"00ff83\",\"nested\":[true,null,1]}', " <>
          "'#{status}', #{attempts}, '2026-11-04 10:00:00.123456', #{dispatched}, #{error}, " <>
          "'2026-11-04 09:59:00.654321', '2026-11-04 10:01:00.000001')",
        []
      )
    end
  end
end
