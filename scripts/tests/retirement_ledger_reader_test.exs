defmodule CoopSubstrate.RetirementLedgerReaderTest do
  use ExUnit.Case, async: false

  alias CoopSubstrate.{
    Canonical,
    EventStore,
    HistoryArchive,
    HistoryArchiveFixture,
    LegacyDb,
    Log,
    ULID
  }

  alias CoopSubstrate.HistoryArchive.{Governance, LedgerReader}
  alias CoopSubstrate.Protocol.Envelope

  # Loaded only by the explicit --restore acceptance entry point, never by
  # the ordinary app-starting test suite. No governance record is signed.
  setup do
    refute Enum.any?(Application.started_applications(), &(elem(&1, 0) == :coop_substrate))
    refute Process.whereis(EventStore)
    {conn, opts} = LegacyDb.create!("retirement_reader")
    prior = Application.fetch_env!(:coop_substrate, EventStore)

    Application.put_env(
      :coop_substrate,
      EventStore,
      opts ++ [serializer: CoopSubstrate.Log.Serializer, column_data_type: "bytea"]
    )

    on_exit(fn -> Application.put_env(:coop_substrate, EventStore, prior) end)
    :ok = Elixir.EventStore.Tasks.Init.exec(EventStore.config(), quiet: true)

    root = Path.join(System.tmp_dir!(), "reader-archive-#{System.unique_integer([:positive])}")
    fixture = HistoryArchiveFixture.build!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{conn: conn, fixture: fixture}
  end

  test "the temporary ledger client is read-only and never starts or repairs the app", c do
    before = counts(c.conn)

    assert :ok =
             LedgerReader.run(fn ->
               refute Enum.any?(
                        Application.started_applications(),
                        &(elem(&1, 0) == :coop_substrate)
                      )

               refute Process.whereis(CoopSubstrate.Supervisor)
               refute Process.whereis(CoopSubstrate.Log)
               refute Process.whereis(CoopSubstrate.Records)

               assert %{rows: [["on"]]} =
                        Postgrex.query!(
                          EventStore.Postgrex,
                          "SHOW default_transaction_read_only",
                          []
                        )

               assert {:error, %Postgrex.Error{postgres: %{code: :read_only_sql_transaction}}} =
                        Postgrex.query(
                          EventStore.Postgrex,
                          "CREATE TABLE forbidden_probe (id int)",
                          []
                        )

               :ok
             end)

    refute Process.whereis(EventStore)

    assert {:error, :archive_record_not_found} =
             HistoryArchive.preflight("chapter-fixture", "spruce_goose",
               archive: c.fixture.dir,
               manifest_sha256: c.fixture.digest,
               archive_event_id: "not-present",
               start_reader: true
             )

    refute Process.whereis(EventStore)
    assert counts(c.conn) == before
    assert %{rows: [[nil]]} = Postgrex.query!(c.conn, "SELECT to_regclass('forbidden_probe')", [])
    refute Enum.any?(Application.started_applications(), &(elem(&1, 0) == :coop_substrate))
  end

  test "verified replay accepts the committed signed vector without creating archive authority",
       c do
    record = presigned_record!()
    head = store_record!(record)
    before = counts(c.conn)

    assert {:ok, governance} = replay(head)
    assert governance.global_seq == 1
    assert governance.error == nil
    assert governance.archives == %{}
    assert MapSet.member?(governance.event_ids, record["event_id"])

    # No derived stream was populated. Neither verification nor preflight may
    # repair one, and an authenticated non-governance event grants no archive.
    assert %{rows: [[0]]} =
             Postgrex.query!(
               c.conn,
               "SELECT count(*) FROM public.streams WHERE stream_uuid = $1",
               [record["stream_id"]]
             )

    assert {:error, :archive_record_not_found} =
             HistoryArchive.preflight(record["chapter_id"], "spruce_goose",
               archive: c.fixture.dir,
               manifest_sha256: c.fixture.digest,
               archive_event_id: record["event_id"],
               start_reader: true
             )

    assert counts(c.conn) == before
    refute Process.whereis(EventStore)
    refute Process.whereis(CoopSubstrate.Log)
    refute Process.whereis(CoopSubstrate.Records)
  end

  test "a one-bit change to the committed signature is refused even with its stored head" do
    record = presigned_record!()
    [%{"key_id" => key_id, "sig" => {:bytes, signature}} = entry] = record["sigs"]
    damaged = %{record | "sigs" => [%{entry | "sig" => {:bytes, flip_first(signature)}}]}
    head = store_record!(damaged)

    assert {:error,
            {:unverified_ledger_prefix,
             {:break, 1, [{:signature, {:invalid_signature, ^key_id}}]}}} = replay(head)
  end

  test "the global chain, stream chain, sequence, and derived stream are independently checked" do
    record = presigned_record!()
    expected_stream = record["stream_id"]

    damaged = %{
      record
      | "global_seq" => 2,
        "stream_seq" => 2,
        "prev_global_hash" => {:bytes, <<1::256>>},
        "prev_stream_hash" => {:bytes, <<2::256>>},
        "stream_id" => "incorrect/derived-stream"
    }

    # Log-assigned fields are outside the signed core. The unchanged committed
    # signature remains valid, so this exercises chain checks specifically.
    assert {:ok, envelope} = Envelope.from_full_record_term(damaged)
    assert :ok = Envelope.verify(envelope)
    head = store_record!(damaged)

    assert {:error,
            {:unverified_ledger_prefix,
             {:break, 1,
              [
                {:global_seq_mismatch, 2},
                :global_chain_break,
                {:stream_seq_mismatch, 2},
                :stream_chain_break,
                {:stream_id_mismatch, "incorrect/derived-stream", ^expected_stream}
              ]}}} = replay(head)
  end

  test "a different pinned head and a shorter stored prefix return no projection" do
    head = presigned_record!() |> store_record!()

    assert {:error, :ledger_head_mismatch} =
             replay(%{head | global_hash: flip_first(head.global_hash)})

    assert {:error, :ledger_head_mismatch} = replay(%{head | global_seq: 2})
  end

  # Reuse only the canonical bytes and signature of the committed envelope-core
  # vector. No private key is retrieved, no signature is generated, and the
  # frozen vector is never regenerated. Only unsigned log fields are added.
  defp presigned_record! do
    path =
      Path.expand("../../apps/coop_substrate/test/vectors/canonical_v1_vectors.json", __DIR__)

    vector =
      path
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("vectors")
      |> Enum.find(&(&1["name"] == "envelope-core"))

    core_bytes = Base.decode16!(vector["canonical_hex"], case: :lower)
    signature = Base.decode16!(vector["sig_hex"], case: :lower)
    assert {:ok, core} = Canonical.decode(core_bytes)
    [%{"key_id" => key_id}] = core["signers"]

    record =
      Map.merge(core, %{
        "sigs" => [%{"key_id" => key_id, "sig" => {:bytes, signature}}],
        "stream_id" => core["chapter_id"] <> "/test",
        "stream_seq" => 1,
        "global_seq" => 1,
        "prev_stream_hash" => nil,
        "prev_global_hash" => nil
      })

    assert {:ok, envelope} = Envelope.from_full_record_term(record)
    assert {:ok, ^core_bytes} = Canonical.encode(Envelope.signed_core_term(envelope))
    assert :ok = Envelope.verify(envelope)
    record
  end

  # The acceptance entry point requires an explicit disposable loopback server,
  # and setup creates a new database for each test. This fixture loader uses
  # EventStore directly; it never invokes the Log appender or a governance API.
  defp store_record!(record) do
    refute Process.whereis(CoopSubstrate.Log)
    refute Process.whereis(CoopSubstrate.Records)
    assert {:ok, bytes} = Canonical.encode(record)
    assert {:ok, event_id} = ULID.to_uuid(record["event_id"])
    assert {:ok, _} = Application.ensure_all_started(:eventstore)
    assert {:ok, writer} = EventStore.start_link(shared_connection_pool: nil)

    try do
      assert :ok =
               EventStore.append_to_stream("ledger", :no_stream, [
                 %Elixir.EventStore.EventData{
                   event_id: event_id,
                   event_type: record["type"],
                   data: bytes,
                   metadata: nil
                 }
               ])
    after
      Supervisor.stop(writer)
    end

    %{global_seq: 1, global_hash: :crypto.hash(:sha256, bytes)}
  end

  defp replay(head), do: LedgerReader.run(fn -> Log.replay_verified(Governance, head) end)
  defp flip_first(<<first, rest::binary>>), do: <<Bitwise.bxor(first, 1), rest::binary>>

  defp counts(conn) do
    for table <- ~w(events stream_events streams), into: %{} do
      {table, Postgrex.query!(conn, "SELECT count(*) FROM public.#{table}", []).rows}
    end
  end
end
