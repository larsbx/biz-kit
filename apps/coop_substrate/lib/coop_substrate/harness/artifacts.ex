defmodule CoopSubstrate.Harness.Artifacts do
  @moduledoc """
  The out-of-log artifact store (Phase 2B; SUBSTRATE.md §7 never-in-log
  rule): recordings, documents, instrument trees, spec/fixture bundles live
  here, content-addressed by SHA-256; the log carries only their hashes.
  `get/1` re-verifies the hash on read — a tampered or corrupted artifact
  fails closed, mirroring the ledger's own audit discipline.

  Filesystem-backed (`:artifact_dir` app env). Erasing an artifact here
  never breaks the chains — that is the point of hash-referencing
  (redactable data is referenced, not embedded).
  """

  @doc "Store a binary; returns its SHA-256 (the log-referenceable hash)."
  @spec put(binary()) :: {:ok, <<_::256>>} | {:error, term()}
  def put(binary) when is_binary(binary) do
    hash = :crypto.hash(:sha256, binary)

    with :ok <- File.mkdir_p(dir()) do
      case :file.open(String.to_charlist(path(hash)), [:write, :binary, :raw, :exclusive]) do
        {:ok, file} ->
          result =
            try do
              with :ok <- :file.write(file, binary), :ok <- :file.sync(file), do: {:ok, hash}
            after
              :file.close(file)
            end

          result

        {:error, :eexist} ->
          with {:ok, ^binary} <- get(hash), do: {:ok, hash}

        error ->
          error
      end
    end
  end

  @custody_limit 8 * 1024 * 1024
  @chunk_size 64 * 1024

  @doc "Streaming verification with a strict I/O bound for serialized custody admission."
  def verify(hash, limit \\ @custody_limit)

  def verify(<<_::256>> = hash, limit) when is_integer(limit) and limit >= 0 do
    read_checked(hash, limit, false)
  end

  @doc "Bounded verified retrieval for custody receipt readers."
  def get_bounded(<<_::256>> = hash), do: read_checked(hash, @custody_limit, true)

  defp read_checked(hash, limit, collect?) do
    case :file.open(String.to_charlist(path(hash)), [:read, :binary, :raw]) do
      {:ok, file} ->
        try do
          stream_checked(
            file,
            hash,
            limit,
            0,
            :crypto.hash_init(:sha256),
            if(collect?, do: [], else: nil)
          )
        after
          :file.close(file)
        end

      {:error, :enoent} ->
        {:error, :not_found}

      error ->
        error
    end
  end

  defp stream_checked(file, expected, limit, size, context, chunks) do
    # Read at most one byte beyond the remaining budget to detect overflow.
    case :file.read(file, min(@chunk_size, limit - size + 1)) do
      {:ok, bytes} when size + byte_size(bytes) > limit ->
        {:error, :artifact_too_large}

      {:ok, bytes} ->
        stream_checked(
          file,
          expected,
          limit,
          size + byte_size(bytes),
          :crypto.hash_update(context, bytes),
          if(chunks == nil, do: nil, else: [bytes | chunks])
        )

      :eof ->
        if :crypto.hash_final(context) == expected do
          with :ok <- :file.sync(file) do
            {:ok,
             if(chunks == nil, do: size, else: chunks |> Enum.reverse() |> IO.iodata_to_binary())}
          end
        else
          {:error, :artifact_tampered}
        end

      error ->
        error
    end
  end

  @doc "Fetch by hash, re-verified on read (fails closed on tamper)."
  @spec get(<<_::256>>) :: {:ok, binary()} | {:error, term()}
  def get(<<_::256>> = hash) do
    case File.read(path(hash)) do
      {:ok, binary} ->
        if :crypto.hash(:sha256, binary) == hash do
          {:ok, binary}
        else
          {:error, :artifact_tampered}
        end

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, _} = error ->
        error
    end
  end

  defp path(hash), do: Path.join(dir(), Base.encode16(hash, case: :lower))

  defp dir do
    Application.get_env(:coop_substrate, :artifact_dir, "priv/artifacts")
  end
end
