defmodule BizKit.Extension.Upgrade do
  @moduledoc """
  Pure, fail-closed compatibility assessment for two ExtensionV1 manifests.

  This is an *upgrade review gate*, not deployment approval, permission,
  migration execution or live installation. No policy result grants an
  extension authority to write business events.

  The safe same-major path preserves declared command/event/projection
  contracts, existing dependencies, and published capabilities. Additions
  are reported for explicit governance review; they are never activated.
  """

  alias BizKit.Extension.Manifest

  @collections [:commands, :events, :projections]
  @lists [:capabilities, :requested_grants, :migrations]

  @spec assess(term(), term()) :: {:ok, map()} | {:error, term()}
  def assess(old, next) do
    with {:ok, previous} <- Manifest.validate(old),
         {:ok, candidate} <- Manifest.validate(next),
         :ok <- id_unchanged(previous, candidate),
         :ok <- version_compatible(previous, candidate),
         :ok <- no_contract_removals(previous, candidate),
         :ok <- dependencies_preserved(previous, candidate),
         :ok <- no_list_removals(previous, candidate) do
      changes = additions(previous, candidate)

      {:ok,
       %{
         id: candidate.id,
         from_version: previous.version,
         to_version: candidate.version,
         classification: if(previous == candidate, do: :unchanged, else: :compatible_additive),
         requires_review: previous != candidate,
         added: changes
       }}
    end
  end

  defp id_unchanged(%{id: id}, %{id: id}), do: :ok
  defp id_unchanged(_, _), do: {:error, :extension_identity_changed}

  defp version_compatible(previous, candidate) do
    old = Version.parse!(previous.version)
    new = Version.parse!(candidate.version)

    cond do
      Version.compare(candidate.version, previous.version) == :lt ->
        {:error, :version_downgrade}

      old.major != new.major ->
        {:error, :major_upgrade_requires_separate_migration}

      previous.version == candidate.version and previous != candidate ->
        {:error, :manifest_changed_without_version_bump}

      true ->
        :ok
    end
  end

  defp no_contract_removals(previous, candidate) do
    Enum.reduce_while(@collections, :ok, fn kind, :ok ->
      current = Map.new(Map.fetch!(candidate, kind), &{&1.name, &1})

      case Enum.find(Map.fetch!(previous, kind), fn entry ->
             Map.get(current, entry.name) != entry
           end) do
        nil -> {:cont, :ok}
        changed -> {:halt, {:error, {:removed_or_changed_contract, kind, changed.name}}}
      end
    end)
  end

  defp dependencies_preserved(previous, candidate) do
    next_deps = Map.new(candidate.dependencies, &{&1.id, &1})

    case Enum.find(previous.dependencies, fn entry ->
           Map.get(next_deps, entry.id) != entry
         end) do
      nil -> :ok
      dep -> {:error, {:removed_or_changed_dependency, dep.id}}
    end
  end

  defp no_list_removals(previous, candidate) do
    # Existing grant requests cannot silently vanish while an application
    # advertises the same contract. Removal deserves explicit migration review.
    Enum.reduce_while(@lists, :ok, fn kind, :ok ->
      current = MapSet.new(Map.fetch!(candidate, kind))

      case Enum.find(Map.fetch!(previous, kind), &(not MapSet.member?(current, &1))) do
        nil -> {:cont, :ok}
        removed -> {:halt, {:error, {:removed_contract_item, kind, removed}}}
      end
    end)
  end

  defp additions(previous, candidate) do
    list_entries =
      Enum.map(@lists, fn kind ->
        existing = MapSet.new(Map.fetch!(previous, kind))

        {kind,
         candidate
         |> Map.fetch!(kind)
         |> Enum.reject(&MapSet.member?(existing, &1))}
      end)

    named_entries =
      Enum.map(@collections, fn kind ->
        existing = MapSet.new(Enum.map(Map.fetch!(previous, kind), & &1.name))

        {kind,
         candidate
         |> Map.fetch!(kind)
         |> Enum.map(& &1.name)
         |> Enum.reject(&MapSet.member?(existing, &1))}
      end)

    dependencies =
      MapSet.new(Enum.map(previous.dependencies, & &1.id))

    added_dependencies =
      candidate.dependencies
      |> Enum.map(& &1.id)
      |> Enum.reject(&MapSet.member?(dependencies, &1))

    Map.new(list_entries ++ named_entries ++ [dependencies: added_dependencies])
  end
end
