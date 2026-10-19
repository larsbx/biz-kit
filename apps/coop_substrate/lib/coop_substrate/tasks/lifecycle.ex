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

  Execution (docs/architecture/2026-10-19-execution.md):

    * start → `TaskStartedV1` (ready → in_progress);
    * submit evidence → `TaskEvidenceSubmittedV2`, citing a custody receipt
      for each criterion of the Definition of Done; the evidence is each
      receipt's digest;
    * review, as a reviewer → `TaskDoDReviewedV1`, accepting or refusing the
      current submission with a reason;
    * complete → `TaskCompletedV1` (in_progress → completed), citing the
      review that accepted it.

  Calling it off (docs/architecture/2026-10-19-cancel-reopen.md):

    * cancel → `TaskCancelledV1` before the work starts, with a reason;
    * reopen → `TaskReopenedV1` (in_progress → queued), with a reason.

  Each task step expects the task's current version, so one prepared before
  someone else changed the task is refused as stale. Whether the step is
  allowed (the state, a Definition of Done, a matching receipt, finished
  predecessors, an accepting review) is the ledger's to say, as for any
  command, before anyone signs.
  """

  @type action ::
          {:propose, String.t()}
          | {:acknowledge_sop, String.t(), String.t()}
          | {:queue, String.t()}
          | {:ready, String.t(), %{String.t() => String.t()}}
          | {:start, String.t()}
          | {:submit_evidence, String.t(), %{String.t() => String.t()}}
          | {:review, String.t(), String.t(), String.t()}
          | {:complete, String.t(), String.t()}
          | {:cancel, String.t(), String.t()}
          | {:reopen, String.t(), String.t()}
          | {:revoke_delegation, String.t()}
          | {:record_custody, <<_::256>>}

  # Definition of Done commands predate lifecycle versions: their actor is
  # principal and grant only.
  @unversioned ~w(TaskEvidenceSubmittedV2 TaskDoDReviewedV1 ArtifactCustodyRecordedV1)

  @spec command(map(), CoopSubstrate.Feed.View.scope(), action(), map()) ::
          {:ok, String.t(), map()} | {:error, term()}
  def command(_o, {_chapter, tenant, project}, {:record_custody, digest}, actor) do
    {:ok, "ArtifactCustodyRecordedV1",
     actor
     |> versioned("ArtifactCustodyRecordedV1")
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

    with %{} = task <- o.tasks[{chapter, tenant, project, task_id}] || {:error, :unknown_task},
         {:ok, type, fields} <- step(o, task, action) do
      {:ok, type,
       actor
       |> versioned(type)
       |> Map.merge(%{
         "tenant_id" => tenant,
         "project_id" => project,
         "task_id" => task_id,
         "expected_version" => task.version
       })
       |> Map.merge(fields)}
    end
  end

  defp versioned(actor, type) when type in @unversioned,
    do: Map.delete(actor, "lifecycle_version")

  defp versioned(actor, _type), do: actor

  defp step(_o, _task, {:propose, _}), do: {:ok, "TaskProposedV1", %{}}
  defp step(_o, _task, {:queue, _}), do: {:ok, "TaskQueuedV1", %{}}
  defp step(_o, _task, {:start, _}), do: {:ok, "TaskStartedV1", %{}}

  defp step(_o, _task, {:acknowledge_sop, _, receipt}),
    do: {:ok, "TaskSOPAcknowledgedV1", %{"custody_receipt_id" => receipt}}

  defp step(_o, _task, {:ready, _, receipts}),
    do: {:ok, "TaskReadyV1", %{"custody_receipts" => receipts}}

  defp step(_o, _task, {:cancel, _, reason}), do: {:ok, "TaskCancelledV1", %{"reason" => reason}}
  defp step(_o, _task, {:reopen, _, reason}), do: {:ok, "TaskReopenedV1", %{"reason" => reason}}

  defp step(_o, _task, {:complete, _, review}),
    do: {:ok, "TaskCompletedV1", %{"review_event_id" => review}}

  defp step(o, %{dod: %{} = dod}, {:submit_evidence, _, receipts}) do
    with {:ok, evidence} <- evidence(o.custody_receipts, receipts) do
      {:ok, "TaskEvidenceSubmittedV2",
       %{
         "definition_event_id" => dod.event_id,
         "evidence" => evidence,
         "custody_receipts" => receipts
       }}
    end
  end

  defp step(_o, %{dod: %{submission: %{} = s} = dod}, {:review, _, decision, reason}) do
    {:ok, "TaskDoDReviewedV1",
     %{
       "definition_event_id" => dod.event_id,
       "submission_event_id" => s.event_id,
       "decision" => decision,
       "reason" => reason
     }}
  end

  defp step(_o, _task, {:submit_evidence, _, _}), do: {:error, {:invalid, :dod_not_defined}}
  defp step(_o, _task, {:review, _, _, _}), do: {:error, {:invalid, :dod_submission_mismatch}}

  # Each criterion's evidence is the digest its receipt holds; whether the
  # receipt is in this project and its bytes are there is the ledger's check.
  defp evidence(known, receipts) do
    Enum.reduce_while(receipts, {:ok, %{}}, fn {criterion, id}, {:ok, acc} ->
      case known[id] do
        %{digest: digest} -> {:cont, {:ok, Map.put(acc, criterion, digest)}}
        nil -> {:halt, {:error, {:invalid, :unknown_custody_receipt}}}
      end
    end)
  end
end
