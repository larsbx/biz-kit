defmodule CoopSubstrate.HistoryArchiveBoundaryTest do
  use ExUnit.Case, async: true

  alias CoopSubstrate.{HistoryArchive, HistoryArchiveFixture}

  setup do
    root = Path.join(System.tmp_dir!(), "archive-boundary-#{System.unique_integer([:positive])}")
    fixture = HistoryArchiveFixture.build!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    fixture
  end

  test "missing required arguments fail before reading a ledger", fixture do
    options = [
      archive: fixture.dir,
      manifest_sha256: fixture.digest,
      archive_event_id: "selected"
    ]

    for key <- Keyword.keys(options) do
      assert {:error, :archive_verification_required} =
               HistoryArchive.preflight(
                 "chapter-fixture",
                 "spruce_goose",
                 Keyword.delete(options, key)
               )
    end

    assert {:error, :archive_verification_required} =
             HistoryArchive.preflight("chapter-fixture", "spruce_goose", :invalid)
  end

  test "missing and corrupted archives are refused before a ledger is needed", fixture do
    options = [
      archive: fixture.dir,
      manifest_sha256: fixture.digest,
      archive_event_id: "selected"
    ]

    assert {:error, {:archive_io, _, :enoent}} =
             HistoryArchive.preflight(
               "chapter-fixture",
               "spruce_goose",
               Keyword.put(options, :archive, Path.join(fixture.dir, "missing"))
             )

    File.write!(Path.join(fixture.dir, "tables/notes.pgcopy"), "changed", [:append])

    assert {:error, {:archive_file_size_mismatch, "tables/notes.pgcopy"}} =
             HistoryArchive.preflight("chapter-fixture", "spruce_goose", options)
  end

  test "source label disagreement is refused before any ledger read", fixture do
    assert {:error, {:archive_source_mismatch, _, _}} =
             HistoryArchive.preflight("chapter-fixture", "spruce_goose",
               archive: fixture.dir,
               manifest_sha256: fixture.digest,
               archive_event_id: "selected",
               expected_source: %{"hostname" => "other.invalid", "database" => "synthetic"}
             )
  end

  test "source-label matching and the no-history case confer no archive authority" do
    actual = %{"hostname" => "fixture.invalid", "database" => "synthetic"}
    assert :ok = HistoryArchive.check_source(actual, actual)
    assert :ok = HistoryArchive.check_source(actual, nil)
    assert {:error, :archive_source_required} = HistoryArchive.check_source(actual, %{})
    assert {:ok, :no_history_required} = HistoryArchive.preflight("chapter-fixture", "eatsbot")
  end

  test "the fence command requires exact archive selection before application or key loading" do
    assert_raise Mix.Error, ~r/archive verification required/, fn ->
      Mix.Tasks.Coop.FenceWriter.run(
        ~w(spruce_goose --chapter chapter-fixture --database-url postgres://fixture.invalid/legacy --reason test --yes)
      )
    end
  end

  test "the read-only command rejects missing selection and unknown options before startup" do
    assert_raise Mix.Error, ~r/usage: mix coop.preflight_writer/, fn ->
      Mix.Tasks.Coop.PreflightWriter.run(
        ~w(spruce_goose --chapter chapter-fixture --archive missing)
      )
    end

    assert_raise Mix.Error, ~r/usage: mix coop.preflight_writer/, fn ->
      Mix.Tasks.Coop.PreflightWriter.run(~w(spruce_goose --yes))
    end
  end

  test "requesting a temporary reader cannot bypass byte verification", fixture do
    assert {:error, :manifest_digest_mismatch} =
             HistoryArchive.preflight("chapter-fixture", "spruce_goose",
               archive: fixture.dir,
               manifest_sha256: String.duplicate("0", 64),
               archive_event_id: "selected",
               start_reader: true
             )
  end
end
