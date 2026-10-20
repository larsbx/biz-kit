defmodule CoopSubstrate.Blueprints do
  @moduledoc """
  Applying a blueprint on the ledger
  (docs/architecture/2026-10-20-hierarchy-and-blueprints.md). Governance's
  tool (`mix coop.blueprint`) verifies the source at the forge and sends the
  exact bytes; the server stores them in custody, decodes and normalizes
  them, and holds a `TaskBlueprintAppliedV1` for the governance key to sign.
  The tool signs only the blueprint it read from the forge itself
  (`expected?/3`). Admission rereads the bytes from custody
  (`TaskHost.read_blueprint/1`).
  """

  alias CoopSubstrate.Commands
  alias CoopSubstrate.Harness.Artifacts

  # A blueprint is a document, not evidence: a megabyte is ample.
  @max_bytes 1_048_576
  @source ~w(repository commit tree path)

  @doc "YAML bytes, decoded (strings only, no atoms) and normalized (`TaskCore.Blueprint`)."
  @spec read(binary()) :: {:ok, TaskCore.Blueprint.t()} | {:error, term()}
  def read(bytes) do
    with {:ok, decoded} <- decode(bytes) do
      case TaskCore.Blueprint.normalize(decoded) do
        {:ok, blueprint} -> {:ok, blueprint}
        {:error, message} -> {:error, {:invalid_blueprint, message}}
      end
    end
  end

  @doc false
  def decode(bytes) do
    case YamlElixir.read_from_string(bytes) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:error, :blueprint_not_yaml}
    end
  end

  @doc """
  Store `bytes` and hold their application to `scope` for `governance_key_id`
  to sign. `source` is the forge identity the tool verified: `repository`,
  `commit`, `tree` and `path`.
  """
  @spec prepare(TaskCore.State.scope(), map(), binary(), String.t()) ::
          {:ok, Commands.pending()} | {:error, term()}
  def prepare({chapter, tenant, project} = scope, source, bytes, governance_key_id) do
    with true <- byte_size(bytes) <= @max_bytes or {:error, :too_large},
         {:ok, signer} <- Commands.governance_signer(chapter, governance_key_id),
         {:ok, blueprint} <- invalid(read(bytes)),
         {:ok, digest} <- Artifacts.put(bytes) do
      Commands.hold(
        {:blueprint, scope},
        chapter,
        "TaskBlueprintAppliedV1",
        source
        |> Map.take(@source)
        |> Map.merge(%{
          "tenant_id" => tenant,
          "project_id" => project,
          "manifest_digest" => {:bytes, digest},
          "blueprint" => blueprint
        }),
        signer
      )
    end
  end

  @doc "Submit the signature for a held application to `scope`."
  def apply(scope, held_id, signature),
    do: Commands.submit({:blueprint, scope}, held_id, signature)

  @doc """
  Whether a held core applies exactly these bytes from exactly this source:
  what the tool checks before it signs.
  """
  def expected?(%{"type" => "TaskBlueprintAppliedV1", "payload" => p}, source, bytes) do
    case read(bytes) do
      {:ok, blueprint} ->
        p["blueprint"] == blueprint and
          p["manifest_digest"] == {:bytes, :crypto.hash(:sha256, bytes)} and
          Map.take(p, @source) == Map.take(source, @source)

      {:error, _} ->
        false
    end
  end

  def expected?(_core, _source, _bytes), do: false

  # Said before anyone signs, as the ledger would refuse it.
  defp invalid({:error, reason}), do: {:error, {:invalid, reason}}
  defp invalid(ok), do: ok
end
