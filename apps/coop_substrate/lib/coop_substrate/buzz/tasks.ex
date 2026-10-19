defmodule CoopSubstrate.Buzz.Tasks do
  @moduledoc """
  Internal, transport-neutral task surface for a Buzz connector.

  Only native signed task proposals are admitted, through the existing ledger
  gate. Buzz keys, membership flags, chat messages, and reactions confer no
  authority here. A caller must retain the exact signed envelope for retries.

  Cards are disposable projections, not completion certificates. `cards/2`
  filters a trusted replay by exact scope; it is NOT a public read endpoint or
  an authorization check. A future transport must authenticate and authorize
  the reader before obtaining that scoped replay. No network call is made.
  """

  alias CoopSubstrate.Protocol.Envelope
  alias CoopSubstrate.Tasks

  @doc "Submit a signed proposal and prepare a notification only after durable acceptance."
  def propose(command, server \\ CoopSubstrate.Log.server())

  def propose(%Envelope{type: "TaskProposedV1"} = command, server) do
    with {:ok, receipt} <- Tasks.propose(command, server) do
      {:ok,
       %{
         receipt: receipt,
         notification: %{
           "delivery_id" => "biz-kit:task:" <> receipt.event_id,
           "ledger_event_id" => receipt.event_id,
           "event_hash" => Base.encode16(receipt.event_hash, case: :lower),
           "global_seq" => receipt.global_seq,
           "chapter_id" => command.chapter_id,
           "tenant_id" => command.payload["tenant_id"],
           "project_id" => command.payload["project_id"],
           "task_id" => command.payload["task_id"],
           "task_version" => receipt.task_version,
           "state" => "proposed"
         }
       }}
    end
  end

  def propose(_command, _server), do: {:error, :not_a_task_proposal}

  @doc "Build deterministically ordered task cards for an explicitly authorized scope."
  def cards(%{tasks: tasks}, {chapter, tenant, project}) when is_map(tasks) do
    if Enum.all?([chapter, tenant, project], &valid_segment?/1) do
      cards =
        tasks
        |> Enum.filter(fn
          {{^chapter, ^tenant, ^project, _task_id}, _task} -> true
          _other -> false
        end)
        |> Enum.sort_by(fn {{_, _, _, task_id}, _task} -> task_id end)
        |> Enum.map(fn {{_, _, _, task_id}, task} ->
          %{
            "chapter_id" => chapter,
            "tenant_id" => tenant,
            "project_id" => project,
            "task_id" => task_id,
            "title" => task.title,
            "state" => task.state,
            "task_version" => task.version,
            "definition_of_done" => task.definition_of_done,
            "definition_ref" => digest(task.definition_ref),
            "dod" => dod_card(Map.get(task, :dod)),
            "ledger_event_id" => task.last_event_id
          }
        end)

      {:ok, cards}
    else
      {:error, :invalid_scope}
    end
  end

  def cards(_state, _scope), do: {:error, :invalid_scope}

  defp dod_card(nil), do: nil

  defp dod_card(dod) do
    %{
      "definition_event_id" => dod.event_id,
      "definition_ref" => digest(dod.definition_ref),
      "criteria" => dod.criteria,
      "submission" =>
        if(dod.submission,
          do: %{
            "custody_receipts" => Map.get(dod.submission, :custody_receipts),
            "event_id" => dod.submission.event_id,
            "principal_id" => dod.submission.principal_id,
            "evidence" =>
              Map.new(dod.submission.evidence, fn {id, hash} -> {id, digest(hash)} end)
          }
        ),
      "review" =>
        if(dod.review,
          do: %{
            "event_id" => dod.review.event_id,
            "principal_id" => dod.review.principal_id,
            "submission_event_id" => dod.review.submission_event_id,
            "decision" => dod.review.decision,
            "reason" => dod.review.reason
          }
        )
    }
  end

  defp digest({:bytes, <<_::256>> = value}), do: Base.encode16(value, case: :lower)

  defp valid_segment?(value) do
    is_binary(value) and byte_size(value) in 1..128 and
      Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/, value)
  end
end
