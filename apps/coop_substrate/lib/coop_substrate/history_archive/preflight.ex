defmodule CoopSubstrate.HistoryArchive.Preflight do
  @moduledoc """
  Strict, read-only checks of the archive selected for SpruceGoose cutover.

  Unlike the generic exporter, this policy requires every retained table to be
  present. It checks the exact manifest digest, file coverage and contents,
  binary COPY framing and counts, required outbox values and state, and adopted
  SOP bytes. It never opens a database, reads governance, signs an event, or
  installs a fence.

  Success proves consistency of the inspected files only. The caller must bind
  the digest to admitted governance and the intended database. Keep the source
  and archive stable through cutover; these checks do not establish immutable
  storage, snapshot freshness, outbox delivery, or a successful database restore.
  """

  import Bitwise, only: [band: 2]

  @writer "spruce_goose"
  @schema "biz-kit.history-archive.v1"
  @tables ~w(actor_grants certified_events notes events ledger_import_receipts grandfathered_baselines outbox_events)
  @outbox_columns ~w(id event_key aggregate_type aggregate_id event_type payload status attempts available_at dispatched_at last_error inserted_at updated_at)
  # 20260728131000_add_transactional_outbox: id is the primary key;
  # explicit null: false fields and timestamps() are non-nullable. Only these
  # two retained columns allow NULL; extra deployment columns keep their policy.
  @outbox_not_null @outbox_columns -- ~w(dispatched_at last_error)
  @magic <<"PGCOPY\n", 255, "\r\n", 0>>
  @chunk_size 65_536

  @doc "Check the selected archive; errors are returned without modifying files."
  def verify(dir, writer, expected_digest)
      when is_binary(dir) and is_binary(writer) and is_binary(expected_digest) do
    try do
      require!(writer == @writer, {:unsupported_archive_writer, writer})
      require!(digest?(expected_digest), :invalid_manifest_digest)
      root = Path.expand(dir)
      present = inventory!(root)
      raw = read!(Path.join(root, "manifest.json"))
      digest = hex(raw)
      require!(digest == expected_digest, :manifest_digest_mismatch)
      manifest = json!(raw, "manifest.json")
      require!(is_map(manifest) and manifest["schema"] == @schema, :invalid_archive_schema)
      require!(manifest["writer"] == writer, :archive_writer_mismatch)
      source = source!(manifest["source"])
      tables = tables!(manifest["tables"])
      files = files!(manifest["files"])

      listed = Enum.map(tables ++ files, & &1["file"])
      require!(Enum.uniq(listed) == listed, :duplicate_archive_path)
      expected = MapSet.new(["manifest.json" | listed])

      require!(
        MapSet.subset?(expected, present),
        {:missing_archive_files, difference(expected, present)}
      )

      require!(
        MapSet.subset?(present, expected),
        {:unlisted_archive_files, difference(present, expected)}
      )

      Enum.each(tables ++ files, &verify_file!(root, &1))

      counts =
        Map.new(tables, fn table ->
          info = copy!(Path.join(root, table["file"]), table)
          require!(info.rows == table["rows"], {:copy_row_count_mismatch, table["name"]})
          {table["name"], info}
        end)

      outbox = manifest["outbox"]
      pending = counts["outbox_events"].undispatched

      require!(
        is_map(outbox) and outbox["table"] == "outbox_events" and
          nonnegative?(outbox["undispatched"]) and outbox["undispatched"] == pending,
        :outbox_count_mismatch
      )

      provenance!(root, files)

      {:ok,
       %{manifest_sha256: digest, writer: writer, source: source, outbox_undispatched: pending}}
    catch
      {:archive_preflight, reason} -> {:error, reason}
    end
  end

  def verify(_, _, _), do: {:error, :invalid_preflight_arguments}

  defp source!(source) do
    require!(
      is_map(source) and nonempty?(source["hostname"]) and nonempty?(source["database"]),
      :invalid_archive_source
    )

    source
  end

  defp tables!(tables) do
    require!(is_list(tables) and Enum.all?(tables, &is_map/1), :invalid_archive_tables)
    names = Enum.map(tables, & &1["name"])
    require!(Enum.sort(names) == Enum.sort(@tables), :required_archive_tables_missing)

    Enum.each(tables, fn table ->
      name = table["name"]
      require!(table["absent"] == false, {:required_archive_table_absent, name})
      require!(table["file"] == "tables/#{name}.pgcopy", {:invalid_archive_path, table["file"]})
      require!(nonnegative?(table["rows"]), {:invalid_archive_rows, name})
      columns = table["columns"]

      require!(
        is_list(columns) and columns != [] and
          Enum.all?(columns, fn c ->
            is_map(c) and nonempty?(c["name"]) and nonempty?(c["type"])
          end),
        {:invalid_archive_columns, name}
      )

      column_names = Enum.map(columns, & &1["name"])
      require!(Enum.uniq(column_names) == column_names, {:duplicate_archive_column, name})
    end)

    tables
  end

  defp files!(files) do
    require!(is_list(files) and Enum.all?(files, &is_map/1), :invalid_archive_files)

    Enum.each(files, fn file ->
      path = file["file"]
      require!(is_binary(path), {:invalid_archive_path, path})

      case String.split(path, "/") do
        ["files", name] when name not in ["", ".", ".."] ->
          require!(not String.contains?(name, ["\\", <<0>>]), {:invalid_archive_path, path})

        _ ->
          refuse({:invalid_archive_path, path})
      end
    end)

    files
  end

  defp inventory!(root) do
    require!(stat!(root).type == :directory, {:not_archive_directory, root})
    root |> walk!("") |> MapSet.new()
  end

  defp walk!(root, relative) do
    path = Path.join(root, relative)

    names =
      case File.ls(path) do
        {:ok, names} -> Enum.sort(names)
        {:error, reason} -> refuse({:archive_io, path, reason})
      end

    Enum.flat_map(names, fn name ->
      child = if relative == "", do: name, else: relative <> "/" <> name

      case stat!(Path.join(root, child)).type do
        :regular -> [child]
        :directory -> walk!(root, child)
        _ -> refuse({:non_regular_archive_entry, child})
      end
    end)
  end

  defp stat!(path) do
    case File.lstat(path) do
      {:ok, stat} -> stat
      {:error, reason} -> refuse({:archive_io, path, reason})
    end
  end

  defp verify_file!(root, item) do
    path = item["file"]

    require!(
      digest?(item["sha256"]) and nonnegative?(item["bytes"]),
      {:invalid_archive_file, path}
    )

    {digest, size} =
      with_file!(Path.join(root, path), &hash_stream!(&1, :crypto.hash_init(:sha256), 0))

    require!(size == item["bytes"], {:archive_file_size_mismatch, path})
    require!(digest == item["sha256"], {:archive_file_digest_mismatch, path})
  end

  defp hash_stream!(io, state, size) do
    case IO.binread(io, @chunk_size) do
      :eof -> {state |> :crypto.hash_final() |> Base.encode16(case: :lower), size}
      {:error, reason} -> refuse({:archive_read, reason})
      bytes -> hash_stream!(io, :crypto.hash_update(state, bytes), size + byte_size(bytes))
    end
  end

  defp copy!(path, table) do
    outbox = outbox_columns!(table)

    with_file!(path, fn io ->
      require!(exact!(io, 11) == @magic, {:invalid_copy, :signature})
      <<flags::unsigned-big-32, extension::signed-big-32>> = exact!(io, 8)
      require!(band(flags, 0xFFFF0000) == 0 and extension >= 0, {:invalid_copy, :header})
      skip!(io, extension)
      copy_rows!(io, length(table["columns"]), outbox, 0, 0)
    end)
  end

  defp outbox_columns!(%{"name" => "outbox_events", "columns" => columns}) do
    names = MapSet.new(columns, & &1["name"])
    require!(MapSet.subset?(MapSet.new(@outbox_columns), names), :invalid_outbox_columns)
    status = Enum.find_index(columns, &(&1["name"] == "status"))
    dispatched = Enum.find_index(columns, &(&1["name"] == "dispatched_at"))
    require!(is_integer(status) and is_integer(dispatched), :invalid_outbox_columns)

    require!(
      Enum.at(columns, status)["type"] == "text" and
        Regex.match?(
          ~r/\Atimestamp(?:\([0-6]\))? (?:with|without) time zone\z/,
          Enum.at(columns, dispatched)["type"]
        ),
      :invalid_outbox_columns
    )

    not_null =
      columns
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {column, index}, required ->
        if column["name"] in @outbox_not_null,
          do: Map.put(required, index, column["name"]),
          else: required
      end)

    %{status: status, dispatched: dispatched, not_null: not_null}
  end

  defp outbox_columns!(_), do: nil

  defp copy_rows!(io, count, outbox, rows, pending) do
    <<fields::signed-big-16>> = exact!(io, 2)

    if fields == -1 do
      require!(IO.binread(io, 1) == :eof, {:invalid_copy, :trailing_data})
      %{rows: rows, undispatched: pending}
    else
      require!(fields == count, {:invalid_copy, :column_count})

      state =
        Enum.reduce(0..(count - 1), %{}, fn index, state ->
          <<size::signed-big-32>> = exact!(io, 4)
          require!(size >= -1, {:invalid_copy, :field_size})

          if outbox && size == -1 do
            case outbox.not_null[index] do
              nil -> :ok
              name -> refuse({:null_outbox_field, name})
            end
          end

          copy_field!(io, index, size, outbox, state)
        end)

      extra =
        if outbox do
          require!(state.status in ["pending", "failed", "dispatched"], :invalid_outbox_status)

          require!(
            state.status == "dispatched" == not state.null_timestamp,
            :outbox_status_mismatch
          )

          if state.null_timestamp, do: 1, else: 0
        else
          0
        end

      copy_rows!(io, count, outbox, rows + 1, pending + extra)
    end
  end

  defp copy_field!(io, index, size, %{status: index}, state) do
    require!(size in 0..32, :invalid_outbox_status)
    Map.put(state, :status, exact!(io, size))
  end

  defp copy_field!(io, index, size, %{dispatched: index}, state) do
    require!(size in [-1, 8], :invalid_outbox_timestamp)
    if size >= 0, do: skip!(io, size)
    Map.put(state, :null_timestamp, size == -1)
  end

  defp copy_field!(io, _index, size, _outbox, state) do
    if size >= 0, do: skip!(io, size)
    state
  end

  defp exact!(_io, 0), do: <<>>

  defp exact!(io, length) do
    case IO.binread(io, length) do
      bytes when is_binary(bytes) and byte_size(bytes) == length -> bytes
      {:error, reason} -> refuse({:archive_read, reason})
      _ -> refuse({:invalid_copy, :truncated})
    end
  end

  defp skip!(_io, 0), do: :ok

  defp skip!(io, length) do
    size = min(length, @chunk_size)
    exact!(io, size)
    skip!(io, length - size)
  end

  defp provenance!(root, files) do
    require!(Enum.any?(files, &(&1["file"] == "files/adopted.json")), :adoption_file_missing)
    adoption = root |> Path.join("files/adopted.json") |> read!() |> json!("files/adopted.json")

    require!(
      is_map(adoption) and adoption["schema"] == "sprucegoose-adopted-artifacts-v1" and
        is_map(adoption["artifacts"]),
      :invalid_adoption_record
    )

    sop = adoption["artifacts"]["systemwide-sop"]
    require!(is_map(sop) and sop["custody"] == "external", :invalid_sop_adoption)

    digest =
      case sop["digest"] do
        "sha256:" <> digest ->
          require!(digest?(digest), :invalid_sop_adoption)
          digest

        _ ->
          refuse(:invalid_sop_adoption)
      end

    require!(
      Enum.any?(files, &(&1["file"] != "files/adopted.json" and &1["sha256"] == digest)),
      :adopted_sop_bytes_missing
    )
  end

  defp json!(raw, name) do
    case Jason.decode(raw, objects: :ordered_objects) do
      {:ok, value} -> unique_json!(value)
      {:error, _} -> refuse({:invalid_archive_json, name})
    end
  end

  defp unique_json!(%Jason.OrderedObject{values: pairs}) do
    Enum.reduce(pairs, %{}, fn {key, value}, map ->
      require!(not Map.has_key?(map, key), {:duplicate_json_key, key})
      Map.put(map, key, unique_json!(value))
    end)
  end

  defp unique_json!(values) when is_list(values), do: Enum.map(values, &unique_json!/1)
  defp unique_json!(value), do: value

  defp read!(path) do
    case File.read(path) do
      {:ok, bytes} -> bytes
      {:error, reason} -> refuse({:archive_io, path, reason})
    end
  end

  defp with_file!(path, fun) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        try do
          fun.(io)
        after
          File.close(io)
        end

      {:error, reason} ->
        refuse({:archive_io, path, reason})
    end
  end

  defp difference(left, right), do: left |> MapSet.difference(right) |> Enum.sort()
  defp nonempty?(value), do: is_binary(value) and byte_size(value) > 0
  defp nonnegative?(value), do: is_integer(value) and value >= 0
  defp digest?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
  defp hex(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp require!(true, _reason), do: :ok
  defp require!(_, reason), do: refuse(reason)
  defp refuse(reason), do: throw({:archive_preflight, reason})
end
