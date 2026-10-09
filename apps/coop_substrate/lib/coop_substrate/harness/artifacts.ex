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

    with :ok <- File.mkdir_p(dir()),
         :ok <- File.write(path(hash), binary) do
      {:ok, hash}
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
