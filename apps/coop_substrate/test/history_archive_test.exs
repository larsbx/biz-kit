defmodule CoopSubstrate.HistoryArchiveTest do
  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.{HistoryArchive, LegacyDb, Log, WriterFence}

  @chapter "chapter-genesis"

  setup do
    gov = new_member("governance")

    {:ok, _} =
      Log.append(
        signed_event(gov, "RoleKeyDeclared", %{
          "role" => "governance",
          "key_id" => gov.signer.key_id,
          "pubkey" => {:bytes, gov.signer.pubkey}
        })
      )

    {legacy, opts} = LegacyDb.create!("history_archive")

    for sql <- [
          "CREATE TABLE certified_events (id bigint PRIMARY KEY, etf bytea NOT NULL, at timestamptz)",
          "CREATE TABLE notes (id int PRIMARY KEY, body text, meta jsonb)",
          "CREATE TABLE outbox_events (id int PRIMARY KEY, dispatched_at timestamptz)",
          "INSERT INTO certified_events VALUES " <>
            "(1, '\\x836803640002686964', '2026-10-01T10:00:00Z'), (2, '\\x00ff', NULL)",
          "INSERT INTO notes VALUES (1, 'kept', '{\"a\": [1, 2]}'), (2, NULL, NULL)",
          "INSERT INTO outbox_events VALUES (1, now())"
        ],
        do: Postgrex.query!(legacy, sql, [])

    root = Path.join(System.tmp_dir!(), "history-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    constitution = Path.join(root, "adopted.json")
    File.write!(constitution, ~s({"artifacts": {}}))

    %{
      legacy: legacy,
      opts: opts,
      out: Path.join(root, "archive"),
      files: [constitution],
      gov: gov,
      root: root,
      signer: Map.put(gov.signer, :seed, gov.seed)
    }
  end

  defp export(c, extra \\ []),
    do: HistoryArchive.export("spruce_goose", c.opts, c.out, [files: c.files] ++ extra)

  defp manifest(dir), do: dir |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()

  test "each table leaves as a lossless binary copy that restores row for row", c do
    assert {:ok, %{manifest_sha256: digest}} = export(c)
    m = manifest(c.out)
    assert m["writer"] == "spruce_goose"
    assert Enum.map(m["tables"], & &1["name"]) == HistoryArchive.spec("spruce_goose").tables

    by_name = Map.new(m["tables"], &{&1["name"], &1})
    assert by_name["actor_grants"]["absent"] == true
    assert %{"rows" => 2, "absent" => false} = by_name["certified_events"]

    assert ["id bigint", "etf bytea", "at timestamp with time zone"] ==
             Enum.map(by_name["certified_events"]["columns"], &"#{&1["name"]} #{&1["type"]}")

    assert [%{"sha256" => _, "file" => "files/adopted.json"}] = m["files"]
    assert {:ok, %{manifest_sha256: ^digest}} = HistoryArchive.verify(c.out)

    # Restore the copies into fresh tables and compare every row.
    for {table, cols} <- [
          {"certified_events", "id bigint, etf bytea NOT NULL, at timestamptz"},
          {"notes", "id int, body text, meta jsonb"}
        ] do
      Postgrex.query!(c.legacy, "CREATE TABLE restored_#{table} (#{cols})", [])
      bytes = File.read!(Path.join(c.out, by_name[table]["file"]))

      {:ok, _} =
        Postgrex.transaction(c.legacy, fn conn ->
          Enum.into(
            [bytes],
            Postgrex.stream(conn, "COPY restored_#{table} FROM STDIN (FORMAT binary)", [])
          )
        end)

      sql = &"SELECT * FROM #{&1} ORDER BY id"

      assert Postgrex.query!(c.legacy, sql.("restored_#{table}"), []).rows ==
               Postgrex.query!(c.legacy, sql.(table), []).rows
    end
  end

  test "verify names every changed, missing or unlisted file", c do
    {:ok, _} = export(c)
    File.write!(Path.join(c.out, "tables/notes.pgcopy"), "edited", [:append])
    File.rm!(Path.join(c.out, "files/adopted.json"))
    File.write!(Path.join(c.out, "tables/extra.pgcopy"), "")

    assert {:error,
            {:mismatch, ["files/adopted.json", "tables/extra.pgcopy", "tables/notes.pgcopy"]}} =
             HistoryArchive.verify(c.out)
  end

  test "an undispatched outbox stops the archive unless deliberately kept", c do
    Postgrex.query!(c.legacy, "INSERT INTO outbox_events VALUES (2, NULL), (3, NULL)", [])
    assert {:error, {:undispatched_outbox, 2}} = export(c)
    refute File.exists?(c.out)

    assert {:ok, _} = export(c, allow_undispatched_outbox: true)
    assert manifest(c.out)["outbox"] == %{"table" => "outbox_events", "undispatched" => 2}
  end

  test "an archive is never written over an existing one", c do
    {:ok, _} = export(c)
    assert {:error, {:exists, _}} = export(c)
  end

  test "only governance records an archive, only for a writer with history to keep", c do
    {:ok, %{manifest_sha256: digest}} = export(c)
    assert {:error, :not_archived} = HistoryArchive.recorded(@chapter, "spruce_goose")
    assert {:ok, _} = HistoryArchive.declare(@chapter, "spruce_goose", digest, c.signer)

    assert {:ok, [%{payload: %{"manifest_sha256" => ^digest}}]} =
             HistoryArchive.recorded(@chapter, "spruce_goose")

    assert {:error, {:reject, 0, {:no_history_to_archive, "eatsbot"}}} =
             HistoryArchive.declare(@chapter, "eatsbot", digest, c.signer)

    assert {:error, {:reject, 0, {:bad_manifest_digest, "nope"}}} =
             HistoryArchive.declare(@chapter, "spruce_goose", "nope", c.signer)

    rogue = new_member("governance")

    assert {:error, {:reject, 0, {:role_key_not_declared, "governance", _}}} =
             HistoryArchive.declare(
               @chapter,
               "spruce_goose",
               digest,
               Map.put(rogue.signer, :seed, rogue.seed)
             )
  end

  test "SpruceGoose is fenced only once its history archive is on the ledger", c do
    {:ok, _} = WriterFence.declare(@chapter, "spruce_goose", "cut over", c.signer)
    assert {:error, :history_not_archived} = WriterFence.install(@chapter, "spruce_goose", c.opts)

    assert {:ok, _} =
             Postgrex.query(c.legacy, "INSERT INTO notes VALUES (3, 'still writable')", [])

    {:ok, %{manifest_sha256: digest}} = export(c)
    {:ok, _} = HistoryArchive.declare(@chapter, "spruce_goose", digest, c.signer)
    assert {:ok, %{tables: 4}} = WriterFence.install(@chapter, "spruce_goose", c.opts)
  end

  test "mix coop.archive_writer exports, records with the governance key, and verifies", c do
    keys = Path.join(c.root, "keys")
    previous = System.get_env("HARNESS_KEYS_DIR")
    System.put_env("HARNESS_KEYS_DIR", keys)
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(Mix.Shell.IO)

      if previous,
        do: System.put_env("HARNESS_KEYS_DIR", previous),
        else: System.delete_env("HARNESS_KEYS_DIR")
    end)

    {:ok, _} = CoopSubstrate.Harness.Ops.gen_key("governance")
    {:ok, key} = CoopSubstrate.Harness.Ops.load_signer("governance")

    {:ok, _} =
      Log.append(
        signed_event(c.gov, "RoleKeyDeclared", %{
          "role" => "governance",
          "key_id" => key.key_id,
          "pubkey" => {:bytes, key.pubkey}
        })
      )

    url = LegacyDb.url(c.opts)
    [sop] = c.files

    archive =
      &Mix.Tasks.Coop.ArchiveWriter.run([
        "spruce_goose",
        "--database-url",
        url,
        "--file",
        sop | &1
      ])

    verify = &Mix.Tasks.Coop.ArchiveWriter.run(["--verify", &1, "--chapter", @chapter])

    # The fence is not even ordered until the history is recorded.
    assert_raise Mix.Error, ~r/record spruce_goose's history first/, fn ->
      Mix.Tasks.Coop.FenceWriter.run(
        ~w(spruce_goose --chapter #{@chapter} --database-url #{url} --reason x --yes)
      )
    end

    assert {:error, :not_ordered} = WriterFence.order(@chapter, "spruce_goose")

    first = Path.join(c.root, "first")
    archive.(["--out", first])
    assert_received {:mix_shell, :info, ["archived: spruce_goose, 7 tables into " <> _]}
    assert File.exists?(Path.join(first, "files/adopted.json"))
    assert_raise Mix.Error, ~r/not recorded on the ledger/, fn -> verify.(first) end

    second = Path.join(c.root, "second")
    archive.(["--out", second, "--chapter", @chapter, "--yes"])

    assert {:ok, [%{signers: [%{key_id: key_id}]}]} =
             HistoryArchive.recorded(@chapter, "spruce_goose")

    assert key_id == key.key_id

    verify.(second)
    assert_received {:mix_shell, :info, ["recorded on the ledger in " <> _]}
    assert_raise Mix.Error, ~r/records other archives/, fn -> verify.(first) end
  end
end
