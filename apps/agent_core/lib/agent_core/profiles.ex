defmodule AgentCore.Profiles do
  @moduledoc """
  Pure, engine-neutral profile lookup across a TRUSTED registry.

  TaskCore records only the immutable (profile ID, profile digest). A platform
  administrator maintains a versioned registry mapping that pair to a known
  adapter and engine-specific parameters. No user/agent string is converted
  into a module or executed. This resolver is NOT a read/run authorization
  check and must be called only after a current ledger gate check.
  """

  @spec resolve(map(), map()) :: {:ok, map()} | {:error, atom()}
  def resolve(%{execution_profile_id: id, execution_profile_digest: digest}, registry)
      when is_binary(id) and is_map(registry) do
    with {:ok, profile} <- fetch(registry, id),
         :ok <- approved(profile, id, digest),
         :ok <- adapter_valid(profile) do
      {:ok, profile}
    end
  end

  def resolve(_run, _registry), do: {:error, :invalid_execution_profile_reference}

  defp fetch(registry, id) do
    case Map.fetch(registry, id) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :execution_profile_not_found}
    end
  end

  defp approved(
         %{id: id, digest: digest, approved: true, adapter: _adapter} = profile,
         expected_id,
         expected_digest
       ) do
    cond do
      id != expected_id -> {:error, :execution_profile_identity_mismatch}
      not match?({:bytes, <<_::256>>}, digest) -> {:error, :invalid_execution_profile_digest}
      digest != expected_digest -> {:error, :execution_profile_digest_mismatch}
      not is_map(Map.get(profile, :parameters)) -> {:error, :invalid_execution_profile_parameters}
      true -> :ok
    end
  end

  defp approved(%{approved: false}, _id, _digest),
    do: {:error, :execution_profile_not_approved}

  defp approved(_profile, _id, _digest), do: {:error, :invalid_execution_profile}

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
