defmodule BizOpsKB.Catalog do
  @moduledoc """
  An inert, verified snapshot of the business-operations knowledge source.

  Loading checks the manifest, relative paths, regular files, byte counts,
  SHA-256 digests and Git blob identities before exposing any document. A
  loaded catalog retains those exact bytes; it never follows a moving branch,
  performs network access, executes content or grants publication authority.

  This module is not an authorization boundary. Hosts must authorize the user
  before calling it or returning metadata, search results or bodies. Returned
  text, including snippets and wiki labels, must be rendered as text, not HTML.
  """

  @enforce_keys [:source, :entries, :by_id]
  defstruct [:source, :entries, :by_id]

  @type t :: %__MODULE__{source: map(), entries: list(), by_id: map()}
  @type load_error :: :invalid_catalog | :content_unavailable | :content_mismatch

  @manifest_keys ~w(schema repository revision tree documents)
  @document_keys ~w(id jd_id title path area category sha256 blob_sha size)
  @max_manifest_bytes 2 * 1024 * 1024
  @max_document_bytes 1024 * 1024
  @max_total_bytes 16 * 1024 * 1024
  @max_documents 1000
  @max_query_bytes 160

  @doc "Load the bundled snapshot, or a snapshot under an explicitly supplied priv root."
  @spec load(keyword()) :: {:ok, t()} | {:error, load_error()}
  def load(opts \\ []) do
    root = Keyword.get_lazy(opts, :root, fn -> Application.app_dir(:bizops_kb, "priv") end)

    with true <- is_binary(root) and String.valid?(root) and not String.contains?(root, <<0>>),
         {:ok, manifest_bytes} <- read_manifest(root),
         {:ok, manifest} <- decode_manifest(manifest_bytes),
         :ok <- validate_manifest(manifest),
         :ok <- directory(Path.join(root, "content")),
         {:ok, entries} <- load_documents(root, manifest) do
      source = Map.take(manifest, ~w(repository revision tree))
      entries = Enum.sort_by(entries, & &1.metadata["path"])

      {:ok,
       %__MODULE__{
         source: source,
         entries: entries,
         by_id: Map.new(entries, &{&1.metadata["id"], &1})
       }}
    else
      false ->
        {:error, :invalid_catalog}

      {:error, reason}
      when reason in [:invalid_catalog, :content_unavailable, :content_mismatch] ->
        {:error, reason}
    end
  end

  @doc "Source provenance and area/category counts. This contains no document bodies."
  @spec summary(t()) :: map()
  def summary(%__MODULE__{} = catalog) do
    areas =
      catalog.entries
      |> Enum.group_by(& &1.metadata["area"])
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {area, entries} ->
        categories =
          entries
          |> Enum.group_by(& &1.metadata["category"])
          |> Enum.sort_by(&elem(&1, 0))
          |> Enum.map(fn {category, documents} ->
            %{"id" => category, "name" => category, "count" => length(documents)}
          end)

        %{"id" => area, "name" => area, "count" => length(entries), "categories" => categories}
      end)

    %{
      "source" => catalog.source,
      "total" => length(catalog.entries),
      "areas" => areas,
      "read_only" => true
    }
  end

  @doc """
  Search titles, IDs and bodies, optionally filtering exact area/category names.

  Results are sorted by source path. Query length is limited to 160 UTF-8
  bytes; malformed/overlong queries return no results and `error: invalid_query`.
  Limits are clamped to 1..100 and offsets to 0..1000. Snippets are plain text.
  """
  @spec search(t(), keyword()) :: map()
  def search(%__MODULE__{} = catalog, opts \\ []) do
    query = Keyword.get(opts, :query, "")
    area = Keyword.get(opts, :area)
    category = Keyword.get(opts, :category)
    limit = bounded_integer(Keyword.get(opts, :limit, 50), 1, 100, 50)
    offset = bounded_integer(Keyword.get(opts, :offset, 0), 0, @max_documents, 0)

    if is_binary(query) and String.valid?(query) and byte_size(query) <= @max_query_bytes and
         valid_filter?(area) and valid_filter?(category) do
      query = query |> String.trim() |> String.downcase()

      matches =
        Enum.filter(catalog.entries, fn entry ->
          (is_nil(area) or area == "" or entry.metadata["area"] == area) and
            (is_nil(category) or category == "" or entry.metadata["category"] == category) and
            String.contains?(entry.search_text, query)
        end)

      documents =
        matches
        |> Enum.slice(offset, limit)
        |> Enum.map(fn entry ->
          Map.put(entry.metadata, "snippet", snippet(entry.body, query))
        end)

      %{
        "documents" => documents,
        "total" => length(matches),
        "offset" => offset,
        "limit" => limit
      }
    else
      %{
        "documents" => [],
        "total" => 0,
        "offset" => offset,
        "limit" => limit,
        "error" => "invalid_query"
      }
    end
  end

  @doc "Return one document's verified bytes and resolvable internal links."
  @spec document(t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def document(%__MODULE__{} = catalog, id) do
    case Map.fetch(catalog.by_id, id) do
      {:ok, entry} ->
        {:ok,
         entry.metadata
         |> Map.put("body", entry.body)
         |> Map.put("links", links(catalog, entry.body, entry.metadata["path"]))}

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Resolve an Obsidian document ID, filename stem, or source-relative path.
  An alias and heading may be present. Ambiguous basenames are refused;
  paths containing traversal, absolute paths and backslashes are refused.
  """
  @spec resolve_link(t(), String.t()) :: {:ok, String.t()} | {:error, :not_found | :ambiguous}
  def resolve_link(%__MODULE__{} = catalog, target) when is_binary(target) do
    target =
      if String.valid?(target) and byte_size(target) <= 2048 do
        target
        |> String.split("|", parts: 2)
        |> hd()
        |> String.split("#", parts: 2)
        |> hd()
        |> String.trim()
      else
        ""
      end

    if safe_path?(target) do
      target = String.replace_suffix(target, ".md", "")

      matches =
        Enum.filter(catalog.entries, fn entry ->
          path = entry.metadata["path"] |> String.replace_suffix(".md", "")
          target in [entry.metadata["id"], path, Path.basename(path)]
        end)

      case matches do
        [entry] -> {:ok, entry.metadata["id"]}
        [] -> {:error, :not_found}
        _ -> {:error, :ambiguous}
      end
    else
      {:error, :not_found}
    end
  end

  def resolve_link(%__MODULE__{}, _), do: {:error, :not_found}

  defp read_manifest(root) do
    path = Path.join(root, "catalog.json")

    with {:ok, %{type: :regular, size: size}} when size <= @max_manifest_bytes <- File.lstat(path),
         {:ok, bytes} <- read_bounded(path, @max_manifest_bytes),
         true <- byte_size(bytes) <= @max_manifest_bytes do
      {:ok, bytes}
    else
      {:error, _} -> {:error, :content_unavailable}
      _ -> {:error, :invalid_catalog}
    end
  end

  # Reject duplicate keys rather than accepting the JSON decoder's last-wins
  # interpretation for a manifest that binds identities to source bytes.
  defp decode_manifest(bytes) do
    decoders = [
      object_start: fn _ -> %{} end,
      object_push: fn key, value, acc ->
        if Map.has_key?(acc, key), do: throw(:duplicate_key), else: Map.put(acc, key, value)
      end,
      object_finish: fn acc, outer -> {acc, outer} end
    ]

    case JSON.decode(bytes, :ok, decoders) do
      {manifest, :ok, ""} -> {:ok, manifest}
      _ -> {:error, :invalid_catalog}
    end
  catch
    :duplicate_key -> {:error, :invalid_catalog}
  end

  defp validate_manifest(manifest) when is_map(manifest) do
    documents = manifest["documents"]

    valid =
      exact_keys?(manifest, @manifest_keys) and manifest["schema"] == 1 and
        valid_repository?(manifest["repository"]) and hex?(manifest["revision"], 40) and
        hex?(manifest["tree"], 40) and is_list(documents) and
        length(documents) in 1..@max_documents and
        Enum.all?(documents, &valid_document?/1) and
        Enum.sum(Enum.map(documents, & &1["size"])) <= @max_total_bytes and
        unique?(documents, "id") and unique?(documents, "path")

    if valid, do: :ok, else: {:error, :invalid_catalog}
  end

  defp validate_manifest(_), do: {:error, :invalid_catalog}

  defp valid_document?(document) when is_map(document) do
    exact_keys?(document, @document_keys) and valid_id?(document) and
      text?(document["title"], 1024) and text?(document["area"], 512) and
      text?(document["category"], 512) and safe_path?(document["path"]) and
      String.ends_with?(document["path"], ".md") and hex?(document["sha256"], 64) and
      hex?(document["blob_sha"], 40) and is_integer(document["size"]) and
      document["size"] in 0..@max_document_bytes
  end

  defp valid_document?(_), do: false

  defp valid_id?(%{"id" => id, "jd_id" => nil}),
    do: is_binary(id) and Regex.match?(~r/\Aref-[0-9a-f]{16}\z/, id)

  defp valid_id?(%{"id" => id, "jd_id" => id}),
    do: is_binary(id) and Regex.match?(~r/\A[0-9]{2}\.[0-9]{2}[a-z]?\z/, id)

  defp valid_id?(_), do: false

  defp valid_repository?(value) when is_binary(value),
    do:
      Regex.match?(
        ~r/\A[A-Za-z0-9_][A-Za-z0-9_.-]{0,99}\/[A-Za-z0-9_][A-Za-z0-9_.-]{0,99}\z/,
        value
      )

  defp valid_repository?(_), do: false

  defp exact_keys?(map, keys), do: Enum.sort(Map.keys(map)) == Enum.sort(keys)

  defp unique?(documents, key),
    do: length(Enum.uniq_by(documents, & &1[key])) == length(documents)

  defp hex?(value, size),
    do: is_binary(value) and byte_size(value) == size and Regex.match?(~r/\A[0-9a-f]+\z/, value)

  defp text?(value, max),
    do:
      is_binary(value) and String.valid?(value) and byte_size(value) in 1..max and
        not Regex.match?(~r/[\x00-\x1f\x7f]/u, value)

  defp safe_path?(path) do
    text?(path, 2048) and not String.contains?(path, "\\") and
      Path.type(path) == :relative and
      not Regex.match?(~r/\A[A-Za-z]:/, path) and
      Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."]))
  end

  defp directory(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} -> :ok
      {:error, _} -> {:error, :content_unavailable}
      _ -> {:error, :invalid_catalog}
    end
  end

  defp load_documents(root, manifest) do
    Enum.reduce_while(manifest["documents"], {:ok, []}, fn metadata, {:ok, entries} ->
      with {:ok, path} <- content_path(root, metadata["path"]),
           {:ok, body} <- read_document(path, metadata) do
        source_url =
          "https://github.com/" <>
            manifest["repository"] <>
            "/blob/" <>
            manifest["revision"] <> "/" <> encode_path(metadata["path"])

        entry = %{
          metadata: Map.put(metadata, "source_url", source_url),
          body: body,
          search_text: String.downcase(Enum.join([metadata["id"], metadata["title"], body], "\n"))
        }

        {:cont, {:ok, [entry | entries]}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # A Mix build's priv root may itself be a trusted symlink. No component
  # below content may be a symlink, even when it ultimately points inside it.
  defp content_path(root, relative) do
    components = String.split(relative, "/")
    {directories, [file]} = Enum.split(components, -1)

    Enum.reduce_while(directories, {:ok, Path.join(root, "content")}, fn part, {:ok, path} ->
      path = Path.join(path, part)

      case directory(path) do
        :ok -> {:cont, {:ok, path}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, path} -> {:ok, Path.join(path, file)}
      error -> error
    end
  end

  defp read_document(path, metadata) do
    with {:ok, %{type: :regular, size: size}} <- File.lstat(path),
         true <- size == metadata["size"] and size <= @max_document_bytes,
         {:ok, bytes} <- read_bounded(path, metadata["size"]),
         true <- String.valid?(bytes) and byte_size(bytes) == metadata["size"],
         true <- digest(:sha256, bytes) == metadata["sha256"],
         true <-
           digest(:sha, ["blob ", Integer.to_string(byte_size(bytes)), <<0>>, bytes]) ==
             metadata["blob_sha"] do
      {:ok, bytes}
    else
      {:ok, %{type: type}} when type != :regular -> {:error, :invalid_catalog}
      {:error, _} -> {:error, :content_unavailable}
      false -> {:error, :content_mismatch}
    end
  end

  # A file growing after lstat must not turn a bounded snapshot read into an
  # unbounded allocation. One additional byte lets the caller detect growth.
  defp read_bounded(path, limit) do
    case File.open(path, [:read, :binary], fn io -> IO.binread(io, limit + 1) end) do
      {:ok, bytes} when is_binary(bytes) -> {:ok, bytes}
      {:ok, :eof} -> {:ok, ""}
      {:ok, {:error, reason}} -> {:error, reason}
      error -> error
    end
  end

  defp digest(algorithm, bytes), do: :crypto.hash(algorithm, bytes) |> Base.encode16(case: :lower)

  defp encode_path(path),
    do:
      path
      |> String.split("/")
      |> Enum.map_join("/", &URI.encode(&1, fn c -> URI.char_unreserved?(c) end))

  defp bounded_integer(value, low, high, _default) when is_integer(value),
    do: min(max(value, low), high)

  defp bounded_integer(_value, _low, _high, default), do: default

  defp valid_filter?(value),
    do: is_nil(value) or (is_binary(value) and String.valid?(value) and byte_size(value) <= 512)

  defp snippet(body, query) do
    lines = String.split(body, ~r/\r?\n/u, trim: true)

    line =
      Enum.find(lines, fn line ->
        query != "" and String.contains?(String.downcase(line), query)
      end) || List.first(lines) || ""

    line |> String.replace(~r/\s+/u, " ") |> String.trim() |> String.slice(0, 220)
  end

  defp links(catalog, body, current_path) do
    wiki =
      Regex.scan(~r/\[\[([^\]\r\n]+)\]\]/u, body, capture: :all_but_first)
      |> Enum.map(fn [link] ->
        [target | alias_parts] = String.split(link, "|", parts: 2)
        target = String.trim(target)
        label = String.trim(List.first(alias_parts) || target)
        link_result(target, label, resolve_link(catalog, target))
      end)

    markdown =
      Regex.scan(~r/!?\[([^\]\r\n]*)\]\(([^)\r\n]+)\)/u, body, capture: :all_but_first)
      |> Enum.reject(fn [_label, target] ->
        Regex.match?(~r/\Ahttps?:\/\//i, String.trim(target))
      end)
      |> Enum.map(fn [label, target] ->
        target = String.trim(target)
        link_result(target, label, relative_link(catalog, target, current_path))
      end)

    Enum.uniq(wiki ++ markdown)
  end

  # Relative Markdown paths have document-local meaning. Normalize them only
  # as catalog names; never expand a filesystem path or read another file.
  # Every final target must be an exact member of the verified catalog.
  defp relative_link(catalog, target, current_path) do
    with true <- String.valid?(target) and byte_size(target) <= 2048,
         {:ok, path} <- decoded_link_path(target),
         {:ok, normalized} <- normalize_relative(path, current_path) do
      case Enum.find(catalog.entries, &(&1.metadata["path"] == normalized)) do
        nil -> {:error, :not_found}
        entry -> {:ok, entry.metadata["id"]}
      end
    else
      _ -> {:error, :not_found}
    end
  end

  defp decoded_link_path(target) do
    {:ok, target |> String.split("#", parts: 2) |> hd() |> URI.decode()}
  rescue
    ArgumentError -> {:error, :not_found}
  end

  defp normalize_relative("", current_path), do: {:ok, current_path}

  defp normalize_relative(path, current_path) do
    valid =
      text?(path, 2048) and not String.contains?(path, "\\") and
        not String.starts_with?(path, "/") and
        not Regex.match?(~r/\A[A-Za-z][A-Za-z0-9+.-]*:/, path) and
        Enum.all?(String.split(path, "/"), &(&1 != ""))

    if valid do
      base = current_path |> String.split("/") |> Enum.drop(-1) |> Enum.reverse()

      Enum.reduce_while(String.split(path, "/"), {:ok, base}, fn
        ".", state -> {:cont, state}
        "..", {:ok, []} -> {:halt, {:error, :not_found}}
        "..", {:ok, [_ | rest]} -> {:cont, {:ok, rest}}
        part, {:ok, parts} -> {:cont, {:ok, [part | parts]}}
      end)
      |> case do
        {:ok, parts} ->
          normalized = parts |> Enum.reverse() |> Enum.join("/")
          if safe_path?(normalized), do: {:ok, normalized}, else: {:error, :not_found}

        error ->
          error
      end
    else
      {:error, :not_found}
    end
  end

  defp link_result(target, label, {:ok, id}),
    do: %{"target" => target, "label" => label, "document_id" => id, "status" => "resolved"}

  defp link_result(target, label, {:error, reason}),
    do: %{
      "target" => target,
      "label" => label,
      "document_id" => nil,
      "status" => Atom.to_string(reason)
    }
end
