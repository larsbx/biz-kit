defmodule AgentCore.Profiles do
  @moduledoc """
  Pure engine-neutral execution profile lookup across a TRUSTED registry.

  TaskCore records only an immutable (profile ID, profile digest).
  Administration publishes a canonical, immutable *data* manifest. The
  coordinating host supplies the same canonical hashing function used when
  that manifest was approved; it must hash ALL execution-relevant settings.
  Neither this library nor a worker maps arbitrary strings to runtime modules.

  The runtime adapter comes from the trusted registry, not the manifest.
  Resolution verifies profile approval and the manifest's current digest.
  It does NOT authorize task reads, agent actions, or actual execution.
  """

  @doc """
  Resolve an execution profile.

  The host MUST provide a canonical digest function for the approved
  manifest, e.g. CoopSubstrate.Canonical.hash!/1 in the biz-kit host. The
  callback accepts an immutable data map (never executable config). A
  malformed or non-canonical manifest is an error, not a fallback. Do not
  supply a hash function that ignores any security-relevant manifest field.
  """
  @spec resolve(map(), map(), (map() -> binary())) :: {:ok, map()} | {:error, atom()}
  def resolve(
        %{execution_profile_id: id, execution_profile_digest: {:bytes, <<_::256>>} = digest},
        registry,
        hash_manifest
      )
      when is_binary(id) and is_map(registry) and is_function(hash_manifest, 1) do
    with {:ok, profile} <- fetch(registry, id),
         :ok <- approved(profile, id),
         :ok <- adapter_valid(profile),
         :ok <- valid_manifest(profile.manifest, id),
         :ok <- digest_matches(profile.manifest, digest, hash_manifest) do
      {:ok, profile}
    end
  end

  def resolve(_run, _registry, _hash_manifest),
    do: {:error, :invalid_execution_profile_reference}

  defp fetch(registry, id) do
    case Map.fetch(registry, id) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :execution_profile_not_found}
    end
  end

  defp approved(%{id: id, approved: true, adapter: _adapter, manifest: _manifest}, id),
    do: :ok

  defp approved(%{approved: false}, _id), do: {:error, :execution_profile_not_approved}

  defp approved(%{id: other}, id) when other != id,
    do: {:error, :execution_profile_identity_mismatch}

  defp approved(_profile, _id), do: {:error, :invalid_execution_profile}

  defp valid_manifest(%{"id" => id, "version" => 1, "parameters" => params} = manifest, id)
       when map_size(manifest) == 3 and is_map(params),
       do: :ok

  defp valid_manifest(_manifest, _id), do: {:error, :invalid_execution_profile_manifest}

  defp digest_matches(manifest, {:bytes, digest}, hash_manifest) do
    case safe_hash(manifest, hash_manifest) do
      {:ok, ^digest} -> :ok
      {:ok, <<_::256>>} -> {:error, :execution_profile_digest_mismatch}
      _ -> {:error, :execution_profile_hash_unavailable}
    end
  end

  defp safe_hash(manifest, hash_manifest) do
    case hash_manifest.(manifest) do
      <<_::256>> = bytes -> {:ok, bytes}
      _ -> {:error, :invalid_hash}
    end
  rescue
    _ -> {:error, :invalid_hash}
  end

  defp adapter_valid(%{adapter: adapter}) when is_atom(adapter) and not is_nil(adapter) do
    if Code.ensure_loaded?(adapter) and
         function_exported?(adapter, :launch, 3) and
         function_exported?(adapter, :poll, 1) and
         function_exported?(adapter, :cancel, 2),
       do: :ok,
       else: {:error, :invalid_execution_adapter}
  end

  defp adapter_valid(_profile), do: {:error, :invalid_execution_adapter}
end
