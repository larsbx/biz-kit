defmodule CoopSubstrate.HistoryArchiveFixture do
  @moduledoc false

  @tables ~w(actor_grants certified_events notes events ledger_import_receipts grandfathered_baselines outbox_events)
  @magic <<"PGCOPY\n", 255, "\r\n", 0>>

  # Synthetic files only. Does not export a database or sign any record.
  def build!(root, opts \\ []) do
    dir = Path.join(root, "archive")
    File.mkdir_p!(Path.join(dir, "tables"))
    File.mkdir_p!(Path.join(dir, "files"))
    pending = Keyword.get(opts, :undispatched, 0)

    outbox_rows =
      [outbox_row(1, "dispatched", 100)] ++
        if(pending > 0,
          do: for(i <- 1..pending, do: outbox_row(i + 1, "pending", nil)),
          else: []
        )

    tables =
      Enum.map(@tables, fn table ->
        {columns, rows} =
          if table == "outbox_events" do
            {outbox_columns(), outbox_rows}
          else
            {[%{"name" => "id", "type" => "bigint"}, %{"name" => "payload", "type" => "bytea"}],
             [[<<1::signed-big-64>>, <<0, 255, "opaque", 131>>]]}
          end

        %{
          "name" => table,
          "absent" => false,
          "file" => "tables/#{table}.pgcopy",
          "rows" => length(rows),
          "columns" => columns
        }
        |> write_item!(dir, binary_copy(rows))
      end)

    paths = provenance_files!(root)

    files =
      Enum.map(paths, fn path ->
        %{"file" => "files/#{Path.basename(path)}", "source" => path}
        |> write_item!(dir, File.read!(path))
      end)

    manifest = %{
      "schema" => "biz-kit.history-archive.v1",
      "writer" => "spruce_goose",
      "source" =>
        Keyword.get(opts, :source, %{"hostname" => "fixture.invalid", "database" => "synthetic"}),
      "taken_at" => "2026-11-23T00:00:00Z",
      "tables" => tables,
      "files" => files,
      "outbox" => %{"table" => "outbox_events", "undispatched" => pending}
    }

    %{
      dir: dir,
      digest: seal!(dir, manifest),
      manifest: manifest,
      outbox_rows: outbox_rows,
      files: paths
    }
  end

  # The legacy migration's complete field set, shared by disposable fixtures.
  def outbox_schema do
    "id uuid PRIMARY KEY, event_key text NOT NULL UNIQUE, aggregate_type text NOT NULL, " <>
      "aggregate_id text NOT NULL, event_type text NOT NULL, payload jsonb NOT NULL, " <>
      "status text NOT NULL, attempts integer NOT NULL, available_at timestamp(6) NOT NULL, " <>
      "dispatched_at timestamp(6), last_error text, inserted_at timestamp(6) NOT NULL, " <>
      "updated_at timestamp(6) NOT NULL"
  end

  def outbox_columns do
    [
      {"id", "uuid"},
      {"event_key", "text"},
      {"aggregate_type", "text"},
      {"aggregate_id", "text"},
      {"event_type", "text"},
      {"payload", "jsonb"},
      {"status", "text"},
      {"attempts", "integer"},
      {"available_at", "timestamp(6) without time zone"},
      {"dispatched_at", "timestamp(6) without time zone"},
      {"last_error", "text"},
      {"inserted_at", "timestamp(6) without time zone"},
      {"updated_at", "timestamp(6) without time zone"}
    ]
    |> Enum.map(fn {name, type} -> %{"name" => name, "type" => type} end)
  end

  def outbox_row(id, status, dispatched_at) do
    attempts = if status == "failed", do: 20, else: if(status == "dispatched", do: 1, else: 0)

    [
      <<id::unsigned-big-128>>,
      "task:t-#{id}:1:0",
      "task",
      "t-#{id}",
      "task.changed",
      <<1>> <> Jason.encode!(%{"task_id" => "t-#{id}", "nested" => [true, nil, 1]}),
      status,
      <<attempts::signed-big-32>>,
      <<100::signed-big-64>>,
      timestamp(dispatched_at),
      if(status == "failed", do: "delivery timeout", else: nil),
      <<50::signed-big-64>>,
      <<150::signed-big-64>>
    ]
  end

  defp timestamp(value) when is_integer(value), do: <<value::signed-big-64>>
  defp timestamp(value), do: value

  def provenance_files!(root) do
    File.mkdir_p!(root)
    sop = Path.join(root, "systemwide-sop.md")
    File.write!(sop, "---\nsop_id: systemwide-sop\nversion: 1\n---\nSynthetic fixture only.\n")
    adopted = Path.join(root, "adopted.json")

    File.write!(
      adopted,
      Jason.encode!(%{
        "schema" => "sprucegoose-adopted-artifacts-v1",
        "artifacts" => %{
          "systemwide-sop" => %{
            "custody" => "external",
            "digest" => "sha256:" <> hex(File.read!(sop))
          },
          "historically-missing" => %{"custody" => "absent", "digest" => nil}
        }
      })
    )

    [adopted, sop]
  end

  def binary_copy(rows) do
    chunks =
      Enum.map(rows, fn row ->
        [
          <<length(row)::signed-big-16>>
          | Enum.map(row, fn
              nil -> <<-1::signed-big-32>>
              bytes -> [<<byte_size(bytes)::signed-big-32>>, bytes]
            end)
        ]
      end)

    IO.iodata_to_binary([
      @magic,
      <<0::unsigned-big-32, 0::signed-big-32>>,
      chunks,
      <<-1::signed-big-16>>
    ])
  end

  def write_item!(item, dir, bytes) do
    File.write!(Path.join(dir, item["file"]), bytes)
    Map.merge(item, %{"sha256" => hex(bytes), "bytes" => byte_size(bytes)})
  end

  def seal!(dir, manifest) do
    bytes = Jason.encode!(manifest, pretty: true)
    File.write!(Path.join(dir, "manifest.json"), bytes)
    hex(bytes)
  end

  def hex(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
