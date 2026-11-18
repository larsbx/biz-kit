defmodule BizKit.Extension.ReleaseLock do
  @moduledoc """
  Source-pinned, dependency-ordered ExtensionV1 release descriptors.

  A release lock binds the exact normalized manifest bytes and a supplied
  source commit for every compiled extension. Source commits MUST be obtained
  and authenticated by a separate trusted build/deployment host: this module
  cannot prove that a SHA belongs to the loaded BEAM code or grant activation.

  Fingerprinting is pure apart from SHA-256; catalog construction calls the
  manifest callbacks of the *trusted* modules provided by the host. No domain
  applications are started by this module, and no grant, deployment approval,
  event or migration is written by it.
  """

  alias BizKit.Extension.{Catalog, Manifest}

  @domain "BizKit.ExtensionV1.Manifest" <> <<0>>
  @commit ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/

  @type lock_item :: %{
          id: String.t(),
          contract_version: 1,
          version: String.t(),
          source_commit: String.t(),
          manifest_sha256: String.t()
        }

  @doc """
  Digest a validated manifest using unambiguous, length-delimited binary
  encoding of sorted map keys and the validated canonical field order.

  This is a *local Elixir V1* digest, not a JSON/wire canonicalization standard.
  """
  @spec fingerprint(term()) :: {:ok, String.t()} | {:error, term()}
  def fingerprint(manifest) do
    with {:ok, canonical} <- Manifest.validate(manifest) do
      digest = :crypto.hash(:sha256, @domain <> IO.iodata_to_binary(encode(canonical)))
      {:ok, Base.encode16(digest, case: :lower)}
    end
  end

  @doc """
  Construct a complete deterministic lock from trusted compiled modules.

  `source_commits` must contain *exactly one* reviewed full Git commit SHA per
  extension ID. A commit supplied by an untrusted caller is not source proof.
  """
  @spec build([module()], map()) :: {:ok, [lock_item()]} | {:error, term()}
  def build(modules, source_commits) do
    with {:ok, _catalog, locked} <- prepare(modules, source_commits) do
      {:ok, locked}
    end
  end

  @doc """
  Refuse a changed/replaced module or source pin without a newly reviewed lock.

  A matching lock only confirms descriptor/source-pin consistency; it is not
  durable governance approval or proof that the supplied source SHA is genuine.
  """
  @spec verify([module()], map(), term()) :: {:ok, [lock_item()]} | {:error, term()}
  def verify(modules, source_commits, expected_lock) do
    with {:ok, _catalog, locked} <- verify_release(modules, source_commits, expected_lock) do
      {:ok, locked}
    end
  end

  @doc """
  Return the same validated catalog snapshot that was checked against the lock.

  A host can publish these descriptors without running manifest callbacks a
  second time. The host supplies trusted modules, source pins and reviewed lock.
  """
  @spec reviewed_catalog([module()], map(), term()) :: {:ok, [map()]} | {:error, term()}
  def reviewed_catalog(modules, source_commits, expected_lock) do
    with {:ok, catalog, _locked} <- verify_release(modules, source_commits, expected_lock) do
      {:ok, catalog}
    end
  end

  defp verify_release(modules, source_commits, expected_lock) when is_list(expected_lock) do
    with {:ok, catalog, locked} <- prepare(modules, source_commits) do
      if locked == expected_lock,
        do: {:ok, catalog, locked},
        else: {:error, :unreviewed_or_stale_release_lock}
    end
  end

  defp verify_release(_, _, _), do: {:error, :invalid_release_lock}

  defp prepare(modules, source_commits) when is_map(source_commits) do
    with {:ok, catalog} <- Catalog.build(modules),
         :ok <- validate_source_commits(catalog, source_commits) do
      locked =
        Enum.map(catalog, fn %{manifest: manifest} ->
          {:ok, digest} = fingerprint(manifest)

          %{
            id: manifest.id,
            contract_version: manifest.contract_version,
            version: manifest.version,
            source_commit: Map.fetch!(source_commits, manifest.id),
            manifest_sha256: digest
          }
        end)

      {:ok, catalog, locked}
    end
  end

  defp prepare(_, _), do: {:error, :invalid_source_commits}

  defp validate_source_commits(catalog, pins) do
    ids = Enum.map(catalog, & &1.manifest.id)

    cond do
      Enum.sort(Map.keys(pins)) != Enum.sort(ids) ->
        {:error, :source_pin_coverage_mismatch}

      Enum.any?(pins, fn {_, sha} ->
        not (is_binary(sha) and Regex.match?(@commit, sha))
      end) ->
        {:error, :invalid_source_commit}

      true ->
        :ok
    end
  end

  # All maps are validated manifest maps with compile-time atom keys; never
  # interpret untrusted strings as atoms. Each constructor has its own type tag.
  defp encode(value) when is_map(value) do
    entries =
      value
      |> Enum.sort_by(fn {key, _value} -> Atom.to_string(key) end)
      |> Enum.map(fn {key, item} -> [encode(key), encode(item)] end)

    ["m", <<map_size(value)::unsigned-32>>, entries]
  end

  defp encode(value) when is_list(value) do
    ["l", <<length(value)::unsigned-32>>, Enum.map(value, &encode/1)]
  end

  defp encode(value) when is_atom(value) do
    tagged("a", Atom.to_string(value))
  end

  defp encode(value) when is_integer(value) do
    tagged("i", Integer.to_string(value))
  end

  defp encode(value) when is_binary(value), do: tagged("s", value)

  defp tagged(tag, binary) do
    [tag, <<byte_size(binary)::unsigned-32>>, binary]
  end
end
