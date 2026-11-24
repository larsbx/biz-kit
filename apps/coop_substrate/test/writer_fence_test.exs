defmodule CoopSubstrate.WriterFenceTest do
  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.{HistoryArchive, HistoryArchiveFixture, Log, WriterFence}

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

    {legacy, opts} = CoopSubstrate.LegacyDb.create!("writer_fence")
    Postgrex.query!(legacy, "CREATE TABLE orders (id int PRIMARY KEY, state text)", [])
    Postgrex.query!(legacy, "CREATE SCHEMA deliveries", [])
    Postgrex.query!(legacy, "CREATE TABLE deliveries.history (id int)", [])
    Postgrex.query!(legacy, "INSERT INTO orders VALUES (1, 'placed')", [])

    %{gov: gov, legacy: legacy, opts: opts, signer: Map.put(gov.signer, :seed, gov.seed)}
  end

  defp refused?(conn, sql) do
    match?(
      {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}},
      Postgrex.query(conn, sql, [])
    )
  end

  test "only governance may order a fence, only for a known writer", %{signer: signer} do
    assert {:ok, _} = WriterFence.declare(@chapter, "eatsbot", "R5 cutover", signer)

    assert {:error, {:reject, 0, {:unknown_writer, "dispatch"}}} =
             WriterFence.declare(@chapter, "dispatch", "not in the set", signer)

    rogue = new_member("governance")

    assert {:error, {:reject, 0, {:role_key_not_declared, "governance", _}}} =
             WriterFence.declare(
               @chapter,
               "eatsbot",
               "x",
               Map.put(rogue.signer, :seed, rogue.seed)
             )
  end

  test "a chapter without declared governance cannot order a fence" do
    stranger = new_member("governance")
    signer = Map.put(stranger.signer, :seed, stranger.seed)
    head = Log.head()

    assert {:error, {:reject, 0, :no_governance}} =
             WriterFence.declare("chapter-other", "eatsbot", "x", signer)

    assert Log.head() == head
  end

  test "archive-before-fence is enforced inside an atomic admission batch", %{gov: gov} do
    archive =
      signed_event(gov, "LegacyHistoryArchived", %{
        "writer" => "spruce_goose",
        "manifest_sha256" => String.duplicate("a", 64)
      })

    fence =
      signed_event(gov, "LegacyWriterFenced", %{
        "writer" => "spruce_goose",
        "reason" => "batch ordering fixture"
      })

    head = Log.head()
    assert {:error, {:reject, 0, :history_not_archived}} = Log.append([fence, archive])
    assert Log.head() == head
    assert {:error, :not_ordered} = WriterFence.order(@chapter, "spruce_goose")

    assert {:ok, [recorded_archive, recorded_fence]} = Log.append([archive, fence])
    assert recorded_archive.global_seq < recorded_fence.global_seq
  end

  test "without a ledger order nothing is installed and writes go on", %{legacy: l, opts: opts} do
    assert {:error, :not_ordered} = WriterFence.install(@chapter, "eatsbot", opts)
    assert {:ok, _} = Postgrex.query(l, "INSERT INTO orders VALUES (2, 'placed')", [])
    assert %{rows: [[nil]]} = Postgrex.query!(l, "SELECT to_regclass('biz_kit_writer_fence')", [])
  end

  test "after the fence every write is refused, reads go on, and it is idempotent",
       %{legacy: l, opts: opts, signer: signer} do
    {:ok, _} = WriterFence.declare(@chapter, "eatsbot", "R5 cutover", signer)
    {:ok, order} = WriterFence.order(@chapter, "eatsbot")

    assert {:ok, %{tables: 3, event_id: event_id}} =
             WriterFence.install(@chapter, "eatsbot", opts)

    assert event_id == order.event_id

    for sql <- [
          "INSERT INTO orders VALUES (2, 'placed')",
          "UPDATE orders SET state = 'ready'",
          "DELETE FROM orders",
          "TRUNCATE orders",
          "INSERT INTO deliveries.history VALUES (1)",
          "DELETE FROM biz_kit_writer_fence"
        ],
        do: assert(refused?(l, sql), sql)

    assert %{rows: [[1, "placed"]]} = Postgrex.query!(l, "SELECT * FROM orders", [])

    assert %{rows: [["eatsbot", @chapter, ^event_id]]} =
             Postgrex.query!(
               l,
               "SELECT writer, chapter_id, event_id FROM biz_kit_writer_fence",
               []
             )

    Postgrex.query!(l, "CREATE TABLE later (id int)", [])
    assert {:ok, %{tables: 4}} = WriterFence.install(@chapter, "eatsbot", opts)
    assert refused?(l, "INSERT INTO later VALUES (1)")
  end

  test "SpruceGoose's fence leaves the task host's tables writable, and a re-run frees them",
       %{legacy: l, opts: opts, signer: signer} do
    for sql <- [
          "CREATE TABLE identity_native_sessions (token_hash bytea PRIMARY KEY)",
          "CREATE TABLE schema_migrations (version bigint PRIMARY KEY)"
        ],
        do: Postgrex.query!(l, sql, [])

    # An earlier, unscoped fence had put its trigger on an exempt table.
    Postgrex.query!(
      l,
      "CREATE FUNCTION biz_kit_refuse_fenced_write() RETURNS trigger LANGUAGE plpgsql AS " <>
        "$$ BEGIN RAISE EXCEPTION 'fenced' USING ERRCODE = 'insufficient_privilege'; END $$",
      []
    )

    Postgrex.query!(
      l,
      "CREATE TRIGGER biz_kit_writer_fence BEFORE INSERT ON identity_native_sessions " <>
        "FOR EACH STATEMENT EXECUTE FUNCTION biz_kit_refuse_fenced_write()",
      []
    )

    root = Path.join(System.tmp_dir!(), "fence-history-#{System.unique_integer([:positive])}")
    files = HistoryArchiveFixture.provenance_files!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    for table <- HistoryArchive.spec("spruce_goose").tables do
      columns =
        if table == "outbox_events",
          do: HistoryArchiveFixture.outbox_schema(),
          else: "id int PRIMARY KEY, payload bytea"

      Postgrex.query!(l, "CREATE TABLE #{table} (#{columns})", [])
    end

    Postgrex.query!(
      l,
      "INSERT INTO outbox_events " <>
        "(id, event_key, aggregate_type, aggregate_id, event_type, payload, status, attempts, " <>
        "available_at, dispatched_at, inserted_at, updated_at) VALUES " <>
        "('00000000-0000-0000-0000-000000000001', 'task:one', 'task', 'one', 'task.changed', " <>
        "'{}', 'dispatched', 1, now(), now(), now(), now())",
      []
    )

    dir = Path.join(root, "archive")
    export_opts = Keyword.put_new(opts, :hostname, "localhost")

    assert {:ok, %{manifest_sha256: digest}} =
             HistoryArchive.export("spruce_goose", export_opts, dir, files: files)

    assert {:ok, [archived]} = HistoryArchive.declare(@chapter, "spruce_goose", digest, signer)
    {:ok, _} = WriterFence.declare(@chapter, "spruce_goose", "legacy writer cut over", signer)

    archive_opts = [archive: dir, manifest_sha256: digest, archive_event_id: archived.event_id]

    assert {:error, :archive_verification_required} =
             WriterFence.install(@chapter, "spruce_goose", opts)

    assert {:error, _} =
             WriterFence.install(
               @chapter,
               "spruce_goose",
               opts,
               Keyword.put(archive_opts, :archive, Path.join(root, "missing"))
             )

    notes = Path.join(dir, "tables/notes.pgcopy")
    intact_notes = File.read!(notes)
    File.write!(notes, "corrupt", [:append])
    assert {:error, _} = WriterFence.install(@chapter, "spruce_goose", opts, archive_opts)
    File.write!(notes, intact_notes)

    expected_source = %{"hostname" => export_opts[:hostname], "database" => opts[:database]}

    assert {:error, {:archive_source_mismatch, _, _}} =
             WriterFence.install(
               @chapter,
               "spruce_goose",
               Keyword.put(opts, :database, "wrong_archive_target"),
               Keyword.put(archive_opts, :expected_source, expected_source)
             )

    assert %{rows: [[nil]]} = Postgrex.query!(l, "SELECT to_regclass('biz_kit_writer_fence')", [])

    # Seven retained tables, orders, deliveries.history and the fence's own
    # table are covered; the two task-host exemptions remain writable.
    assert {:ok, %{tables: 10, archive_verification: %{manifest_sha256: ^digest}}} =
             WriterFence.install(@chapter, "spruce_goose", opts, archive_opts)

    assert {:ok, %{tables: 10}} =
             WriterFence.install(@chapter, "spruce_goose", opts, archive_opts)

    assert refused?(l, "INSERT INTO orders VALUES (2, 'placed')")
    assert refused?(l, "DELETE FROM biz_kit_writer_fence")

    assert {:ok, _} =
             Postgrex.query(l, "INSERT INTO identity_native_sessions VALUES ('\\x01')", [])

    assert {:ok, _} =
             Postgrex.query(l, "INSERT INTO schema_migrations VALUES (20261021120000)", [])

    assert WriterFence.exempt("eatsbot") == []
  end

  test "a conflicting database fence record is refused without changing triggers or rows", %{
    legacy: legacy,
    opts: opts,
    signer: signer
  } do
    {:ok, _} = WriterFence.declare(@chapter, "eatsbot", "cut over", signer)
    {:ok, order} = WriterFence.order(@chapter, "eatsbot")

    Postgrex.query!(
      legacy,
      "CREATE TABLE public.biz_kit_writer_fence (" <>
        "writer text PRIMARY KEY, chapter_id text NOT NULL, event_id text NOT NULL, " <>
        "fenced_at timestamptz NOT NULL DEFAULT now())",
      []
    )

    for {chapter, event} <- [{"chapter-other", order.event_id}, {@chapter, "other-order"}] do
      Postgrex.query!(
        legacy,
        "INSERT INTO public.biz_kit_writer_fence (writer, chapter_id, event_id) " <>
          "VALUES ('eatsbot', $1, $2) ON CONFLICT (writer) DO UPDATE " <>
          "SET chapter_id = EXCLUDED.chapter_id, event_id = EXCLUDED.event_id",
        [chapter, event]
      )

      assert {:error,
              {:fence_order_conflict,
               %{
                 writer: "eatsbot",
                 expected: %{chapter_id: @chapter, event_id: expected_event},
                 recorded: [[^chapter, ^event]]
               }}} = WriterFence.install(@chapter, "eatsbot", opts)

      assert expected_event == order.event_id

      assert %{rows: [[^chapter, ^event]]} =
               Postgrex.query!(
                 legacy,
                 "SELECT chapter_id, event_id FROM public.biz_kit_writer_fence " <>
                   "WHERE writer = 'eatsbot'",
                 []
               )

      assert %{rows: [[0]]} =
               Postgrex.query!(
                 legacy,
                 "SELECT count(*) FROM pg_trigger WHERE tgname = 'biz_kit_writer_fence'",
                 []
               )

      assert {:ok, _} = Postgrex.query(legacy, "UPDATE orders SET state = 'still writable'", [])
    end
  end

  test "a write in flight at cutover commits before the fence; none after it",
       %{legacy: l, opts: opts, signer: signer} do
    {:ok, _} = WriterFence.declare(@chapter, "eatsbot", "R5 cutover", signer)
    parent = self()

    writer =
      Task.async(fn ->
        Postgrex.transaction(l, fn conn ->
          Postgrex.query!(conn, "INSERT INTO orders VALUES (2, 'placed')", [])
          send(parent, :writing)
          receive do: (:commit -> :ok)
        end)
      end)

    assert_receive :writing
    fence = Task.async(fn -> WriterFence.install(@chapter, "eatsbot", opts) end)
    refute Task.yield(fence, 300), "the fence must wait for the writer holding the table"
    send(writer.pid, :commit)
    assert {:ok, :ok} = Task.await(writer)
    assert {:ok, %{tables: 3}} = Task.await(fence)

    assert %{rows: [[2]]} = Postgrex.query!(l, "SELECT count(*) FROM orders", [])
    assert refused?(l, "INSERT INTO orders VALUES (3, 'placed')")
  end

  test "mix coop.fence_writer signs the order with the governance key and fences", %{
    gov: existing,
    legacy: l,
    opts: opts
  } do
    dir = Path.join(System.tmp_dir!(), "fence-keys-#{System.unique_integer([:positive])}")
    previous = System.get_env("HARNESS_KEYS_DIR")
    System.put_env("HARNESS_KEYS_DIR", dir)
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      File.rm_rf!(dir)
      Mix.shell(Mix.Shell.IO)

      if previous,
        do: System.put_env("HARNESS_KEYS_DIR", previous),
        else: System.delete_env("HARNESS_KEYS_DIR")
    end)

    {:ok, _} = CoopSubstrate.Harness.Ops.gen_key("governance")
    {:ok, gov} = CoopSubstrate.Harness.Ops.load_signer("governance")

    {:ok, _} =
      Log.append(
        signed_event(existing, "RoleKeyDeclared", %{
          "role" => "governance",
          "key_id" => gov.key_id,
          "pubkey" => {:bytes, gov.pubkey}
        })
      )

    url = CoopSubstrate.LegacyDb.url(opts)

    run =
      &Mix.Tasks.Coop.FenceWriter.run([
        "eatsbot",
        "--chapter",
        @chapter,
        "--database-url",
        url | &1
      ])

    assert_raise Mix.Error, ~r/--reason is required/, fn -> run.(["--yes"]) end
    assert {:error, :not_ordered} = WriterFence.order(@chapter, "eatsbot")

    run.(["--reason", "R5 cutover", "--yes"])
    assert_received {:mix_shell, :info, ["Order the fence of eatsbot" <> _]}
    assert_received {:mix_shell, :info, ["fenced: eatsbot, 3 tables, order " <> _]}
    assert {:ok, %{signers: [%{key_id: key_id}]}} = WriterFence.order(@chapter, "eatsbot")
    assert key_id == gov.key_id
    assert refused?(l, "INSERT INTO orders VALUES (2, 'placed')")
  end
end
