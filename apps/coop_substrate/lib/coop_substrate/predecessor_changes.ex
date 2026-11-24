defmodule CoopSubstrate.PredecessorChanges do
  @moduledoc """
  Governance changes an ad hoc task's predecessor list at its reviewed version.
  The existing readiness event checks the graph, keeps the input and SOP
  commitments, and clears the previous acknowledgment.
  """

  alias CoopSubstrate.{Commands, Log}
  alias TaskCore.Admission

  @type_name "TaskReadinessDefinedV1"

  def snapshot({_chapter, tenant, project, id} = key) do
    case Log.gate().orchestration.tasks[key] do
      %{blueprint: %{}} ->
        {:error, :blueprint_predecessors_fixed}

      %{readiness: readiness, version: version, state: state} when is_map(readiness) ->
        {:ok,
         %{
           "tenant_id" => tenant,
           "project_id" => project,
           "task_id" => id,
           "expected_version" => version,
           "state" => state,
           "predecessor_ids" => readiness.predecessor_ids,
           "sop_digest" => hex(readiness.sop_digest),
           "sop_version" => readiness[:sop_version],
           "artifact_requirements" =>
             Map.new(readiness.artifact_requirements, fn {k, v} -> {k, hex(v)} end)
         }}

      nil ->
        {:error, :unknown_task}

      _ ->
        {:error, :readiness_not_defined}
    end
  end

  def prepare({chapter, _, _, _} = key, operation, predecessor, version, key_id) do
    with {:ok, current} <- snapshot(key),
         true <- current["expected_version"] == version or {:error, :stale_task_version},
         {:ok, payload} <- replacement(current, operation, predecessor),
         {:ok, signer} <- Commands.governance_signer(chapter, key_id) do
      Commands.hold({:predecessor_change, key}, chapter, @type_name, payload, signer)
    end
  end

  def submit(key, hold, signature),
    do: Commands.submit({:predecessor_change, key}, hold, signature)

  @doc "Construct the exact payload the CLI checks before signing."
  def replacement(
        %{
          "task_id" => task,
          "state" => state,
          "predecessor_ids" => ids,
          "sop_digest" => sop,
          "artifact_requirements" => inputs
        } = current,
        operation,
        predecessor
      )
      when is_list(ids) and is_map(inputs) do
    with true <- state in ~w(proposed queued) or {:error, :readiness_edit_state},
         true <-
           (Admission.segment?(predecessor) and predecessor != task) or
             {:error, :invalid_predecessor},
         {:ok, ids} <- edit(ids, operation, predecessor),
         {:ok, sop} <- digest(sop),
         {:ok, inputs} <- digests(inputs) do
      payload =
        current
        |> Map.take(~w(tenant_id project_id task_id expected_version sop_version))
        |> Map.merge(%{
          "predecessor_ids" => ids,
          "sop_digest" => sop,
          "artifact_requirements" => inputs
        })

      {:ok,
       if(payload["sop_version"] == nil, do: Map.delete(payload, "sop_version"), else: payload)}
    end
  end

  def replacement(_, _, _), do: {:error, :invalid_readiness_snapshot}

  def expected?(
        %{"type" => @type_name, "chapter_id" => chapter, "auth_ref" => nil, "payload" => payload},
        chapter,
        expected
      ),
      do: payload === expected

  def expected?(_, _, _), do: false

  defp edit(ids, "add", id) do
    if id in ids, do: {:error, :predecessor_exists}, else: {:ok, ids ++ [id]}
  end

  defp edit(ids, "remove", id) do
    if id in ids, do: {:ok, List.delete(ids, id)}, else: {:error, :unknown_predecessor_edge}
  end

  defp edit(_, _, _), do: {:error, :bad_request}
  defp hex({:bytes, bytes}), do: Base.encode16(bytes, case: :lower)

  defp digest(value) when is_binary(value) do
    case Base.decode16(value, case: :lower) do
      {:ok, <<_::256>> = bytes} -> {:ok, {:bytes, bytes}}
      _ -> {:error, :invalid_readiness_snapshot}
    end
  end

  defp digest(_), do: {:error, :invalid_readiness_snapshot}

  defp digests(inputs) do
    Enum.reduce_while(inputs, {:ok, %{}}, fn {name, value}, {:ok, acc} ->
      case digest(value) do
        {:ok, decoded} -> {:cont, {:ok, Map.put(acc, name, decoded)}}
        error -> {:halt, error}
      end
    end)
  end
end
