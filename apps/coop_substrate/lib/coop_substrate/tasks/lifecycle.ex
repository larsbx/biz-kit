defmodule CoopSubstrate.Tasks.Lifecycle do
  @moduledoc """
  A person's lifecycle step on a task, as the command they sign
  (docs/architecture/2026-10-19-lifecycle.md). Pure.

    * propose → `TaskProposedV1` (inbox → proposed);
    * acknowledge the SOP → `TaskSOPAcknowledgedV1`, citing a custody
      receipt of the SOP the readiness definition names;
    * queue → `TaskQueuedV1` (proposed → queued);
    * ready → `TaskReadyV1` (queued → ready), citing a custody receipt for
      each required input;
    * revoke a delegation they made → `TaskDelegationRevokedV1`;
    * record custody of an artifact they stored → `ArtifactCustodyRecordedV1`
      (docs/architecture/2026-10-19-uploads.md), which the ledger admits
      only once the bytes are in the store.

  Each task step expects the task's current version, so one prepared before
  someone else changed the task is refused as stale. Whether the step is
  allowed (the state, a Definition of Done, a matching receipt, finished
  predecessors) is the ledger's to say, as for any command, before anyone
  signs.
  """

  @type action ::
          {:propose, String.t()}
          | {:acknowledge_sop, String.t(), String.t()}
          | {:queue, String.t()}
          | {:ready, String.t(), %{String.t() => String.t()}}
          | {:revoke_delegation, String.t()}
          | {:record_custody, <<_::256>>}

  @types %{
    propose: "TaskProposedV1",
    acknowledge_sop: "TaskSOPAcknowledgedV1",
    queue: "TaskQueuedV1",
    ready: "TaskReadyV1"
  }

  @spec command(map(), CoopSubstrate.Feed.View.scope(), action(), map()) ::
          {:ok, String.t(), map()} | {:error, atom()}
  # Custody predates lifecycle versions: its actor is principal and grant only.
  def command(_o, {_chapter, tenant, project}, {:record_custody, digest}, actor) do
    {:ok, "ArtifactCustodyRecordedV1",
     actor
     |> Map.delete("lifecycle_version")
     |> Map.merge(%{
       "tenant_id" => tenant,
       "project_id" => project,
       "artifact_digest" => {:bytes, digest}
     })}
  end

  def command(o, {chapter, tenant, project}, {:revoke_delegation, id}, actor) do
    case o.delegations[id] do
      %{chapter_id: ^chapter, tenant_id: ^tenant, project_id: ^project} ->
        {:ok, "TaskDelegationRevokedV1",
         Map.merge(actor, %{
           "tenant_id" => tenant,
           "project_id" => project,
           "delegation_event_id" => id
         })}

      _ ->
        {:error, :unknown_delegation}
    end
  end

  def command(o, {chapter, tenant, project}, action, actor) do
    task_id = elem(action, 1)

    case o.tasks[{chapter, tenant, project, task_id}] do
      nil ->
        {:error, :unknown_task}

      task ->
        {:ok, @types[elem(action, 0)],
         actor
         |> Map.merge(%{
           "tenant_id" => tenant,
           "project_id" => project,
           "task_id" => task_id,
           "expected_version" => task.version
         })
         |> Map.merge(cites(action))}
    end
  end

  defp cites({:acknowledge_sop, _, receipt}), do: %{"custody_receipt_id" => receipt}
  defp cites({:ready, _, receipts}), do: %{"custody_receipts" => receipts}
  defp cites(_action), do: %{}
end
