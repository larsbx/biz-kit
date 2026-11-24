defmodule CoopSubstrate.HistoryArchivePreflightTest do
  use ExUnit.Case, async: true

  alias CoopSubstrate.HistoryArchive.Preflight
  alias CoopSubstrate.HistoryArchiveFixture, as: Fixture

  setup do
    root = Path.join(System.tmp_dir!(), "archive-preflight-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    Map.put(Fixture.build!(root), :root, root)
  end

  defp verify(c), do: Preflight.verify(c.dir, "spruce_goose", c.digest)

  defp manifest(c, fun) do
    m = fun.(c.manifest)
    %{c | manifest: m, digest: Fixture.seal!(c.dir, m)}
  end

  defp table(c, name), do: Enum.find(c.manifest["tables"], &(&1["name"] == name))

  defp table_bytes(c, name, bytes, fields \\ %{}) do
    updated = c |> table(name) |> Fixture.write_item!(c.dir, bytes) |> Map.merge(fields)

    manifest(
      c,
      &Map.update!(&1, "tables", fn ts ->
        Enum.map(ts, fn t -> if t["name"] == name, do: updated, else: t end)
      end)
    )
  end

  defp file_bytes(c, name, bytes) do
    item = Enum.find(c.manifest["files"], &(&1["file"] == name))
    updated = Fixture.write_item!(item, c.dir, bytes)

    manifest(
      c,
      &Map.update!(&1, "files", fn fs ->
        Enum.map(fs, fn f -> if f["file"] == name, do: updated, else: f end)
      end)
    )
  end

  defp snapshot(dir) do
    dir
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Map.new(&{Path.relative_to(&1, dir), File.read!(&1)})
  end

  test "complete synthetic archive verifies without changing any byte", c do
    before = snapshot(c.dir)
    assert {:ok, result} = verify(c)

    assert result == %{
             manifest_sha256: c.digest,
             writer: "spruce_goose",
             source: c.manifest["source"],
             outbox_undispatched: 0
           }

    assert snapshot(c.dir) == before
  end

  test "preserved undispatched rows are counted, not certified as delivered", c do
    fixture = Fixture.build!(Path.join(c.root, "pending"), undispatched: 2)
    assert {:ok, %{outbox_undispatched: 2}} = verify(fixture)
  end

  test "missing archive and manifest are typed failures", c do
    assert {:error, {:archive_io, _, :enoent}} =
             Preflight.verify(Path.join(c.root, "missing"), "spruce_goose", c.digest)

    File.rm!(Path.join(c.dir, "manifest.json"))
    assert {:error, {:archive_io, _, :enoent}} = verify(c)
  end

  test "malformed manifest returns an error after exact digest binding", c do
    File.write!(Path.join(c.dir, "manifest.json"), "{")

    assert {:error, {:invalid_archive_json, "manifest.json"}} =
             verify(%{c | digest: Fixture.hex("{")})
  end

  test "raw manifest digest must equal the selected recorded digest", c do
    assert {:error, :manifest_digest_mismatch} = verify(%{c | digest: String.duplicate("0", 64)})
    assert {:error, :invalid_manifest_digest} = verify(%{c | digest: "not-a-digest"})
  end

  test "unknown writer, invalid schema and wrong manifest writer are refused", c do
    assert {:error, {:unsupported_archive_writer, "eatsbot"}} =
             Preflight.verify(c.dir, "eatsbot", c.digest)

    assert {:error, :invalid_archive_schema} =
             c |> manifest(&Map.put(&1, "schema", "other")) |> verify()

    assert {:error, :archive_writer_mismatch} =
             c |> manifest(&Map.put(&1, "writer", "eatsbot")) |> verify()
  end

  test "source labels must be present for the caller's database binding", c do
    assert {:error, :invalid_archive_source} =
             c |> manifest(&Map.put(&1, "source", %{})) |> verify()
  end

  test "empty lists and coherent omitted table/file do not satisfy coverage", c do
    assert {:error, :required_archive_tables_missing} =
             c |> manifest(&Map.put(&1, "tables", [])) |> verify()

    File.rm!(Path.join(c.dir, "tables/outbox_events.pgcopy"))

    c =
      manifest(
        c,
        &Map.update!(&1, "tables", fn ts ->
          Enum.reject(ts, fn t -> t["name"] == "outbox_events" end)
        end)
      )

    assert {:error, :required_archive_tables_missing} = verify(c)
  end

  test "absent and duplicated required tables are refused", c do
    absent = Map.put(table(c, "actor_grants"), "absent", true)
    c1 = manifest(c, &Map.update!(&1, "tables", fn ts -> [absent | tl(ts)] end))
    assert {:error, {:required_archive_table_absent, "actor_grants"}} = verify(c1)
    c2 = manifest(c, &Map.update!(&1, "tables", fn ts -> [hd(ts) | ts] end))
    assert {:error, :required_archive_tables_missing} = verify(c2)
  end

  test "missing listed table bytes are named", c do
    File.rm!(Path.join(c.dir, "tables/outbox_events.pgcopy"))
    assert {:error, {:missing_archive_files, ["tables/outbox_events.pgcopy"]}} = verify(c)
  end

  test "same-length corruption and file size changes are refused", c do
    path = Path.join(c.dir, "tables/notes.pgcopy")
    <<first, rest::binary>> = File.read!(path)
    File.write!(path, <<Bitwise.bxor(first, 1), rest::binary>>)
    assert {:error, {:archive_file_digest_mismatch, "tables/notes.pgcopy"}} = verify(c)
    File.write!(path, "extra", [:append])
    assert {:error, {:archive_file_size_mismatch, "tables/notes.pgcopy"}} = verify(c)
  end

  test "duplicate file descriptors and traversal paths are refused", c do
    c1 = manifest(c, &Map.update!(&1, "files", fn fs -> [hd(fs) | fs] end))
    assert {:error, :duplicate_archive_path} = verify(c1)

    c2 =
      manifest(
        c,
        &Map.update!(&1, "files", fn [first | rest] ->
          [Map.put(first, "file", "files/../adopted.json") | rest]
        end)
      )

    assert {:error, {:invalid_archive_path, "files/../adopted.json"}} = verify(c2)
  end

  test "hidden unlisted files and symlinks are refused", c do
    File.write!(Path.join(c.dir, ".extra"), "extra")
    assert {:error, {:unlisted_archive_files, [".extra"]}} = verify(c)
    File.rm!(Path.join(c.dir, ".extra"))
    File.ln_s!(Path.join(c.root, "systemwide-sop.md"), Path.join(c.dir, "files/link"))
    assert {:error, {:non_regular_archive_entry, "files/link"}} = verify(c)
  end

  test "a duplicate JSON key cannot silently replace an authenticated field", c do
    raw = File.read!(Path.join(c.dir, "manifest.json"))
    <<"{", rest::binary>> = raw
    bytes = ~s({"writer":"spruce_goose",) <> rest
    File.write!(Path.join(c.dir, "manifest.json"), bytes)
    assert {:error, {:duplicate_json_key, "writer"}} = verify(%{c | digest: Fixture.hex(bytes)})
  end

  test "COPY row count and field count are checked even when all hashes match", c do
    c1 = table_bytes(c, "notes", Fixture.binary_copy([]))
    assert {:error, {:copy_row_count_mismatch, "notes"}} = verify(c1)
    c2 = table_bytes(c, "notes", Fixture.binary_copy([["one field"]]))
    assert {:error, {:invalid_copy, :column_count}} = verify(c2)
  end

  test "truncated COPY with updated size and digest is refused", c do
    bytes = File.read!(Path.join(c.dir, "tables/notes.pgcopy"))
    c = table_bytes(c, "notes", binary_part(bytes, 0, byte_size(bytes) - 3))
    assert {:error, {:invalid_copy, :truncated}} = verify(c)
  end

  test "COPY header, lengths, and trailer are checked", c do
    original = File.read!(Path.join(c.dir, "tables/notes.pgcopy"))
    <<magic::binary-size(11), _header::binary-size(8), rows::binary>> = original

    for {bytes, reason} <- [
          {<<0, binary_part(original, 1, byte_size(original) - 1)::binary>>, :signature},
          {<<magic::binary, 0x10000::unsigned-big-32, 0::signed-big-32, rows::binary>>, :header},
          {<<magic::binary, 0::unsigned-big-32, -1::signed-big-32, rows::binary>>, :header},
          {original <> "trailing", :trailing_data},
          {<<magic::binary, 0::unsigned-big-32, 0::signed-big-32, 2::signed-big-16,
             -2::signed-big-32>>, :field_size}
        ] do
      assert {:error, {:invalid_copy, ^reason}} = c |> table_bytes("notes", bytes) |> verify()
    end
  end

  test "COPY noncritical header flags and extension bytes are supported", c do
    original = File.read!(Path.join(c.dir, "tables/notes.pgcopy"))
    <<magic::binary-size(11), _header::binary-size(8), rows::binary>> = original
    updated = <<magic::binary, 1::unsigned-big-32, 6::signed-big-32, "opaque", rows::binary>>
    assert {:ok, _} = c |> table_bytes("notes", updated) |> verify()
  end

  test "a shorter outbox with recomputed hashes is checked against recorded counts", c do
    fixture = Fixture.build!(Path.join(c.root, "pending"), undispatched: 2)
    fewer = fixture.outbox_rows |> Enum.take(2) |> Fixture.binary_copy()
    c1 = table_bytes(fixture, "outbox_events", fewer)
    assert {:error, {:copy_row_count_mismatch, "outbox_events"}} = verify(c1)
    c2 = table_bytes(fixture, "outbox_events", fewer, %{"rows" => 2})
    assert {:error, :outbox_count_mismatch} = verify(c2)
  end

  test "outbox manifest count is verified against COPY NULL timestamp fields", c do
    c = manifest(c, &Map.put(&1, "outbox", %{"table" => "outbox_events", "undispatched" => 1}))
    assert {:error, :outbox_count_mismatch} = verify(c)
  end

  test "outbox status and timestamp contradictions are refused", c do
    for row <- [
          Fixture.outbox_row(1, "pending", 100),
          Fixture.outbox_row(1, "dispatched", nil)
        ] do
      assert {:error, :outbox_status_mismatch} =
               c |> table_bytes("outbox_events", Fixture.binary_copy([row])) |> verify()
    end
  end

  test "a failed outbox row with NULL timestamp is preserved and counted", c do
    bytes = Fixture.binary_copy([Fixture.outbox_row(1, "failed", nil)])

    c =
      c
      |> table_bytes("outbox_events", bytes)
      |> manifest(&Map.put(&1, "outbox", %{"table" => "outbox_events", "undispatched" => 1}))

    assert {:ok, %{outbox_undispatched: 1}} = verify(c)
  end

  test "outbox status and timestamp encodings are checked", c do
    assert {:error, :invalid_outbox_status} =
             c
             |> table_bytes(
               "outbox_events",
               Fixture.binary_copy([Fixture.outbox_row(1, "unknown", nil)])
             )
             |> verify()

    assert {:error, :invalid_outbox_timestamp} =
             c
             |> table_bytes(
               "outbox_events",
               Fixture.binary_copy([Fixture.outbox_row(1, "dispatched", "short")])
             )
             |> verify()
  end

  test "outbox must retain its status and timestamp columns", c do
    for name <- ["status", "dispatched_at"] do
      columns = table(c, "outbox_events")["columns"]
      index = Enum.find_index(columns, &(&1["name"] == name))
      rows = Enum.map(c.outbox_rows, &List.delete_at(&1, index))

      modified =
        table_bytes(c, "outbox_events", Fixture.binary_copy(rows), %{
          "columns" => List.delete_at(columns, index)
        })

      assert {:error, :invalid_outbox_columns} = verify(modified)
    end
  end

  test "coherently omitted outbox payload or event key cannot pass recomputed hashes", c do
    for name <- ["payload", "event_key"] do
      columns = table(c, "outbox_events")["columns"]
      index = Enum.find_index(columns, &(&1["name"] == name))
      rows = Enum.map(c.outbox_rows, &List.delete_at(&1, index))

      modified =
        table_bytes(c, "outbox_events", Fixture.binary_copy(rows), %{
          "columns" => List.delete_at(columns, index)
        })

      assert {:error, :invalid_outbox_columns} = verify(modified)
    end
  end

  test "additional preserved outbox columns remain allowed", c do
    columns =
      table(c, "outbox_events")["columns"] ++ [%{"name" => "future_metadata", "type" => "bytea"}]

    rows = Enum.map(c.outbox_rows, &(&1 ++ [<<0, 255, 131>>]))
    modified = table_bytes(c, "outbox_events", Fixture.binary_copy(rows), %{"columns" => columns})
    assert {:ok, %{outbox_undispatched: 0}} = verify(modified)
  end

  test "required outbox values cannot be replaced with NULL under recomputed hashes", c do
    for name <-
          ~w(id event_key aggregate_type aggregate_id event_type payload status attempts available_at inserted_at updated_at) do
      columns = table(c, "outbox_events")["columns"]
      index = Enum.find_index(columns, &(&1["name"] == name))
      rows = Enum.map(c.outbox_rows, &List.replace_at(&1, index, nil))
      modified = table_bytes(c, "outbox_events", Fixture.binary_copy(rows))

      assert {:error, {:null_outbox_field, ^name}} = verify(modified)
    end
  end

  test "nullable outbox values and extra columns survive reordered columns", c do
    columns =
      Enum.reverse(table(c, "outbox_events")["columns"]) ++
        [%{"name" => "future_metadata", "type" => "bytea"}]

    # Pending delivery has no dispatch timestamp or last error. The added
    # column is also nullable; the known required fields are located by name.
    row = Enum.reverse(Fixture.outbox_row(1, "pending", nil)) ++ [nil]

    modified =
      c
      |> table_bytes("outbox_events", Fixture.binary_copy([row]), %{"columns" => columns})
      |> manifest(&Map.put(&1, "outbox", %{"table" => "outbox_events", "undispatched" => 1}))

    assert {:ok, %{outbox_undispatched: 1}} = verify(modified)
  end

  test "adopted.json cannot be coherently omitted from the file list", c do
    File.rm!(Path.join(c.dir, "files/adopted.json"))

    c =
      manifest(
        c,
        &Map.update!(&1, "files", fn fs ->
          Enum.reject(fs, fn f -> f["file"] == "files/adopted.json" end)
        end)
      )

    assert {:error, :adoption_file_missing} = verify(c)
  end

  test "a different SOP remains refused after updating its manifest hash", c do
    assert {:error, :adopted_sop_bytes_missing} =
             c |> file_bytes("files/systemwide-sop.md", "wrong SOP") |> verify()
  end

  test "malformed adoption record has a typed error", c do
    assert {:error, {:invalid_archive_json, "files/adopted.json"}} =
             c |> file_bytes("files/adopted.json", "{") |> verify()
  end

  test "source freshness is outside a self-consistent file verification", c do
    # This control does not claim source authenticity: a coherently replaced
    # archive needs a newly admitted digest and independent source verification.
    c = c |> table_bytes("notes", Fixture.binary_copy([]), %{"rows" => 0})
    assert {:ok, _} = verify(c)
  end
end
