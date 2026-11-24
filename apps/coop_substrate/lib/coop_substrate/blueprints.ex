defmodule CoopSubstrate.Blueprints do
  @moduledoc """
  Applying a blueprint on the ledger
  (docs/architecture/2026-10-20-hierarchy-and-blueprints.md). Governance's
  tool (`mix coop.blueprint`) verifies the source at the forge and sends the
  exact bytes; the server stores them in custody, decodes and normalizes
  them, and holds a `TaskBlueprintAppliedV1` for the governance key to sign.
  The tool signs only the blueprint it read from the forge itself
  (`expected?/4`). Admission rereads the bytes from custody
  (`TaskHost.read_blueprint/1`).
  """

  alias CoopSubstrate.Commands
  alias CoopSubstrate.Harness.Artifacts

  # A blueprint is a document, not evidence: a megabyte is ample.
  @max_bytes 1_048_576
  @source ~w(repository commit tree path)
  @registered "TaskBlueprintRegisteredV1"
  @applied "TaskBlueprintAppliedV1"

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
  def prepare(scope, source, bytes, governance_key_id),
    do: prepare(scope, source, bytes, governance_key_id, :apply)

  def prepare({chapter, tenant, project} = scope, source, bytes, governance_key_id, mode)
      when mode in [:apply, :register] do
    with true <- byte_size(bytes) <= @max_bytes or {:error, :too_large},
         {:ok, signer} <- Commands.governance_signer(chapter, governance_key_id),
         {:ok, blueprint} <- invalid(read(bytes)),
         {:ok, digest} <- Artifacts.put(bytes) do
      Commands.hold(
        owner(scope, mode),
        chapter,
        type(mode),
        source
        |> Map.take(fields(mode))
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
    do: submit(scope, held_id, signature, :apply)

  def submit(scope, held_id, signature, mode),
    do: Commands.submit(owner(scope, mode), held_id, signature)

  # Keep applications already held across the introduction of registration.
  defp owner(scope, :apply), do: {:blueprint, scope}
  defp owner(scope, :register), do: {:blueprint_registration, scope}
  defp type(:apply), do: @applied
  defp type(:register), do: @registered
  defp fields(:apply), do: ["registration_event_id" | @source]
  defp fields(:register), do: @source

  @doc """
  Whether a held core applies exactly these bytes from exactly this source
  to exactly this scope: what the tool checks before it signs.
  """
  def expected?(core, scope, source, bytes), do: expected?(core, scope, source, bytes, :apply)

  def expected?(
        %{"type" => type, "chapter_id" => chapter, "payload" => p, "auth_ref" => nil},
        {chapter, tenant, project},
        source,
        bytes,
        mode
      )
      when is_map(p) do
    case read(bytes) do
      {:ok, blueprint} ->
        type == type(mode) and
          {p["tenant_id"], p["project_id"]} == {tenant, project} and
          p["blueprint"] == blueprint and
          p["manifest_digest"] == {:bytes, :crypto.hash(:sha256, bytes)} and
          Map.take(p, fields(mode)) == Map.take(source, fields(mode))

      {:error, _} ->
        false
    end
  end

  def expected?(_core, _scope, _source, _bytes, _mode), do: false

  # Said before anyone signs, as the ledger would refuse it.
  defp invalid({:error, reason}), do: {:error, {:invalid, reason}}
  defp invalid(ok), do: ok
end
