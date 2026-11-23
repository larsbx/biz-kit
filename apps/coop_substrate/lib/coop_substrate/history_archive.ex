defmodule CoopSubstrate.HistoryArchive do
  @moduledoc """
  A retired writer's history, kept as inert audit data before its fence
  (docs/architecture/2026-11-06-sprucegoose-decommission.md, §3). Nothing in
  an archive converts into ledger authorization.

  1. `export/4` copies each table the writer's spec names out of its database,
     in ONE repeatable-read snapshot, as PostgreSQL binary `COPY` (lossless,
     `bytea` included), with its column types and a SHA-256 per file. Files
     the records reference (the constitution, the Systemwide SOP) are copied
     beside them. `manifest.json` lists every file and digest; a table the
     database lacks is listed as absent. An outbox with undispatched rows
     stops the export unless they are deliberately kept, and the manifest
     records how many.
  2. `verify/1` re-hashes an archive against its manifest and names every
     changed, missing or unlisted file.
  3. Governance signs `LegacyHistoryArchived` (`writer`, `manifest_sha256`).
     `CoopSubstrate.WriterFence` installs a fence for a writer with a spec
     only once such a record exists, so history is copied before writes stop.
  """

  alias CoopSubstrate.Log
  alias CoopSubstrate.Protocol.{Envelope, TypeRegistry}

  @type_name "LegacyHistoryArchived"
  @schema "biz-kit.history-archive.v1"
  @manifest "manifest.json"
  # What each retired writer keeps (§3). Default files are relative to the
  # umbrella root; deployment-local ones are passed to `export/4`.
  @specs %{
    "spruce_goose" => %{
      tables:
        ~w(actor_grants certified_events notes events ledger_import_receipts grandfathered_baselines outbox_events),
      outbox: "outbox_events",
      files: ["apps/spruce_goose/priv/constitution/adopted.json"]
    }
  }

  @doc "The history a writer keeps, or nil if it keeps none."
  def spec(writer), do: @specs[writer]

  def event_types do
    %{
      @type_name => %{
        required_roles: ["governance"],
        disclosure_class: :commons,
        stream: {:payload_field, "writer-archives", "writer"},
        payload: %{required: %{"writer" => :string, "manifest_sha256" => :string}, optional: %{}}
      }
    }
  end

  @doc "Append-gate check: a writer with history, a SHA-256, declared governance."
  def check(
        %Envelope{chapter_id: chapter, payload: %{"writer" => w, "manifest_sha256" => d}},
        gate
      ) do
    cond do
      spec(w) == nil -> {:error, {:no_history_to_archive, w}}
      not (d =~ ~r/\A[0-9a-f]{64}\z/) -> {:error, {:bad_manifest_digest, d}}
      map_size(gate.role_keys[{chapter, "governance"}] || %{}) == 0 -> {:error, :no_governance}
      true -> :ok
    end
  end

  @doc "Sign and append the archive record with a governance signer."
  def declare(chapter, writer, manifest_sha256, signer) do
    with {:ok, env} <-
           Envelope.new(%{
             chapter_id: chapter,
             type: @type_name,
             payload: %{"writer" => writer, "manifest_sha256" => manifest_sha256},
             signers: [Map.take(signer, [:role, :key_id, :pubkey])],
             timestamp_ms: System.system_time(:millisecond)
           }),
         {:ok, env} <- Envelope.sign(env, signer.key_id, signer.seed) do
      Log.append(env)
    end
  end

  @doc "Every archive recorded for `writer` in `chapter`, oldest first."
  def recorded(chapter, writer) do
    with {:ok, stream} <- TypeRegistry.stream_id(@type_name, chapter, %{"writer" => writer}),
         {:ok, [_ | _] = envs} <- Log.read_stream(stream) do
      {:ok, envs}
    else
      {:ok, []} -> {:error, :not_archived}
      error -> error
    end
  end

  @doc "`:ok` once a writer that keeps history has an archive on the ledger."
  def ready_to_fence(chapter, writer) do
    cond do
      spec(writer) == nil -> :ok
      match?({:ok, _}, recorded(chapter, writer)) -> :ok
      true -> {:error, :history_not_archived}
    end
  end

  @doc """
  Export `writer`'s history from `conn_opts` (Postgrex options) into the new
  directory `dir`. Options: `files` (paths to copy beside the tables),
  `allow_undispatched_outbox` (default false).
  """
  def export(writer, conn_opts, dir, opts \\ []) do
    spec = spec(writer) || raise ArgumentError, "#{writer} keeps no history"
    staging = "#{dir}.partial-#{System.unique_integer([:positive])}"
    files = Keyword.get(opts, :files, [])

    with :ok <- distinct_names(files),
         false <- File.exists?(dir),
         {:ok, _} <- Application.ensure_all_started(:postgrex),
         {:ok, conn} <- Postgrex.start_link(conn_opts) do
      try do
        File.mkdir_p!(Path.join(staging, "tables"))
        File.mkdir_p!(Path.join(staging, "files"))

        with {:ok, {tables, outbox}} <-
               Postgrex.transaction(conn, &snapshot!(&1, spec, staging, opts), timeout: :infinity) do
          files = Enum.map(files, &copy_file!(&1, staging))

          manifest =
            Jason.encode!(
              %{
                "schema" => @schema,
                "writer" => writer,
                "source" =>
                  Map.new(Keyword.take(conn_opts, [:hostname, :database]), fn {k, v} ->
                    {"#{k}", v}
                  end),
                "taken_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
                "tables" => tables,
                "files" => files,
                "outbox" => outbox
              },
              pretty: true
            )

          File.write!(Path.join(staging, @manifest), manifest)
          File.rename!(staging, dir)
          {:ok, %{manifest_sha256: hex(manifest), dir: dir, tables: length(tables)}}
        end
      rescue
        error in Postgrex.Error -> {:error, error}
      after
        GenServer.stop(conn)
        File.rm_rf!(staging)
      end
    else
      true -> {:error, {:exists, dir}}
      error -> error
    end
  end

  # Files land under their base names, so two sources may not share one.
  defp distinct_names(files) do
    case files
         |> Enum.map(&Path.basename/1)
         |> Enum.frequencies()
         |> Enum.find(&(elem(&1, 1) > 1)) do
      nil -> :ok
      {name, _} -> {:error, {:duplicate_file_name, name}}
    end
  end

  defp snapshot!(conn, spec, staging, opts) do
    Postgrex.query!(conn, "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY", [])
    outbox = %{"table" => spec.outbox, "undispatched" => undispatched!(conn, spec.outbox)}

    if outbox["undispatched"] > 0 and not Keyword.get(opts, :allow_undispatched_outbox, false),
      do: Postgrex.rollback(conn, {:undispatched_outbox, outbox["undispatched"]})

    {Enum.map(spec.tables, &table!(conn, &1, staging)), outbox}
  end

  defp undispatched!(conn, table) do
    if present?(conn, table),
      do: count!(conn, "SELECT count(*) FROM public.#{table} WHERE dispatched_at IS NULL"),
      else: 0
  end

  defp table!(conn, name, staging) do
    if present?(conn, name) do
      file = "tables/#{name}.pgcopy"

      digest =
        write_hashed!(Path.join(staging, file), fn io ->
          conn
          |> Postgrex.stream("COPY public.#{name} TO STDOUT (FORMAT binary)", [])
          |> Stream.flat_map(& &1.rows)
          |> Enum.each(&IO.binwrite(io, &1))
        end)

      %{
        "name" => name,
        "absent" => false,
        "rows" => count!(conn, "SELECT count(*) FROM public.#{name}"),
        "columns" => columns!(conn, name),
        "file" => file
      }
      |> Map.merge(digest)
    else
      %{"name" => name, "absent" => true}
    end
  end

  defp present?(conn, name),
    do:
      Postgrex.query!(conn, "SELECT to_regclass($1) IS NOT NULL", ["public.#{name}"]).rows == [
        [true]
      ]

  defp count!(conn, sql), do: hd(hd(Postgrex.query!(conn, sql, []).rows))

  defp columns!(conn, name) do
    Postgrex.query!(
      conn,
      "SELECT attname, format_type(atttypid, atttypmod) FROM pg_attribute " <>
        "WHERE attrelid = $1::text::regclass AND attnum > 0 AND NOT attisdropped ORDER BY attnum",
      ["public.#{name}"]
    ).rows
    |> Enum.map(fn [col, type] -> %{"name" => col, "type" => type} end)
  end

  defp copy_file!(source, staging) do
    file = "files/#{Path.basename(source)}"
    File.cp!(source, Path.join(staging, file))
    Map.merge(%{"source" => source, "file" => file}, digest!(Path.join(staging, file)))
  end

  defp write_hashed!(path, fun) do
    File.open!(path, [:write, :binary], fun)
    digest!(path)
  end

  defp digest!(path) do
    sha =
      path
      |> File.stream!(65_536)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    %{"sha256" => sha, "bytes" => File.stat!(path).size}
  end

  defp hex(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  @doc "Re-hash an archive against its manifest."
  def verify(dir) do
    raw = File.read!(Path.join(dir, @manifest))
    manifest = Jason.decode!(raw)

    listed =
      Map.new(
        for(%{"absent" => false} = t <- manifest["tables"], do: {t["file"], t["sha256"]}) ++
          for(f <- manifest["files"], do: {f["file"], f["sha256"]})
      )

    present =
      for path <- Path.wildcard(Path.join(dir, "**/*")),
          File.regular?(path),
          rel = Path.relative_to(path, dir),
          rel != @manifest,
          into: %{},
          do: {rel, digest!(path)["sha256"]}

    mismatched =
      (Map.keys(listed) ++ Map.keys(present))
      |> Enum.uniq()
      |> Enum.reject(&(listed[&1] != nil and listed[&1] == present[&1]))
      |> Enum.sort()

    if mismatched == [],
      do: {:ok, %{manifest_sha256: hex(raw), writer: manifest["writer"]}},
      else: {:error, {:mismatch, mismatched}}
  end
end
