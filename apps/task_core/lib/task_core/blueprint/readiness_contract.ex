defmodule TaskCore.Blueprint.ReadinessContract do
  @moduledoc """
  Optional immutable readiness bindings for a schema-2 workflow.

  Governance's adopted blueprint fixes the SOP and source input digests. The
  reserved `workflow_manifest` input is bound to the adoption event's exact
  manifest digest when adoption is folded, avoiding a document hashing itself.
  A bound contract is checked at ordinary readiness admission, regardless of
  which client prepared the command. This adds no event, writer or execution.
  """

  @fields ~w(schema_version sop_digest sop_version input_digests manifest_input)
  @identifier ~r/\A[a-z0-9][a-z0-9_-]{0,127}\z/
  @digest ~r/\A[0-9a-f]{64}\z/
  @version ~r/\A(0|[1-9]\d{0,8})\.(0|[1-9]\d{0,8})\.(0|[1-9]\d{0,8})\z/
  @manifest_input "workflow_manifest"

  @doc "Validate the complete version-1 contract, retaining only its declared shape."
  @spec normalize(term()) :: {:ok, map()} | {:error, String.t()}
  def normalize(%{"schema_version" => 1, "manifest_input" => @manifest_input} = contract)
      when map_size(contract) == 5 do
    with true <- Enum.sort(Map.keys(contract)) == Enum.sort(@fields),
         true <- matches?(@digest, contract["sop_digest"]),
         true <- matches?(@version, contract["sop_version"]),
         true <- inputs?(contract["input_digests"]) do
      {:ok, contract}
    else
      _ -> {:error, "readiness_contract has invalid fields"}
    end
  end

  def normalize(_), do: {:error, "readiness_contract must be a complete version-1 mapping"}

  @doc "Every task must require every source input and the adopted manifest, exactly once."
  @spec task_inputs(map(), [map()]) :: :ok | {:error, String.t()}
  def task_inputs(contract, tasks) do
    expected = Enum.sort([@manifest_input | Map.keys(contract["input_digests"])])

    if Enum.all?(tasks, &(Enum.sort(&1["artifact_requirements"]) == expected)),
      do: :ok,
      else:
        {:error,
         "readiness_contract inputs must exactly match every task's artifact_requirements"}
  end

  @doc "Bind a validated contract to the accepted blueprint's retained manifest digest."
  @spec bind(map(), {:bytes, <<_::256>>}) :: map()
  def bind(contract, {:bytes, <<_::256>>} = manifest_digest) do
    %{
      sop_digest: bytes(contract["sop_digest"]),
      sop_version: contract["sop_version"],
      artifact_requirements:
        contract["input_digests"]
        |> Map.new(fn {name, digest} -> {name, bytes(digest)} end)
        |> Map.put(@manifest_input, manifest_digest)
    }
  end

  @doc "Require the exact bound SOP, version and complete input-digest map."
  @spec check(map(), map()) :: :ok | {:error, :blueprint_readiness_contract_mismatch}
  def check(%{sop_digest: sop, sop_version: version, artifact_requirements: inputs}, payload) do
    if payload["sop_digest"] == sop and payload["sop_version"] == version and
         payload["artifact_requirements"] == inputs,
       do: :ok,
       else: {:error, :blueprint_readiness_contract_mismatch}
  end

  def check(_, _), do: {:error, :blueprint_readiness_contract_mismatch}

  defp inputs?(inputs) when is_map(inputs) and map_size(inputs) in 1..31 do
    not Map.has_key?(inputs, @manifest_input) and
      Enum.all?(inputs, fn {name, digest} ->
        matches?(@identifier, name) and matches?(@digest, digest)
      end)
  end

  defp inputs?(_), do: false

  defp matches?(pattern, value),
    do: is_binary(value) and byte_size(value) <= 128 and Regex.match?(pattern, value)

  defp bytes(hex), do: {:bytes, Base.decode16!(hex, case: :lower)}
end
