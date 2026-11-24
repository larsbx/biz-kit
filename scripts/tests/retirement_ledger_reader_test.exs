defmodule CoopSubstrate.RetirementLedgerReaderTest do
  use ExUnit.Case, async: false

  alias CoopSubstrate.{EventStore, HistoryArchive, HistoryArchiveFixture, LegacyDb}
  alias CoopSubstrate.HistoryArchive.LedgerReader

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

  defp counts(conn) do
    for table <- ~w(events stream_events streams), into: %{} do
      {table, Postgrex.query!(conn, "SELECT count(*) FROM public.#{table}", []).rows}
    end
  end
end
