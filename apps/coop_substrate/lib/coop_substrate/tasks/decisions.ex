defmodule CoopSubstrate.Tasks.Decisions do
  @moduledoc """
  An operator's decision on a pending suggestion, as the command the operator
  signs (docs/architecture/2026-10-18-decide.md). Pure.

    * accept a timing suggestion → `TaskTimingRevisedV1` with the suggested
      timing, expecting the task's current timing version;
    * accept a create suggestion → `TaskCreatedV1` with the suggested title,
      timing and description;
    * decline → `TaskSuggestionDeclinedV1` with the reason.

  Accepting copies the suggestion's body unchanged, so the ledger records it
  as `accepted`, not `amended`.
  """

  @type decision :: {:accept, String.t()} | {:decline, String.t(), String.t()}

  @spec command(map(), CoopSubstrate.Feed.View.scope(), decision(), map()) ::
          {:ok, String.t(), map()} | {:error, atom()}
  def command(o, scope, decision, actor) do
    with {:ok, s} <- pending(o, scope, elem(decision, 1)) do
      base = Map.merge(actor, %{"tenant_id" => s.tenant_id, "project_id" => s.project_id})
      build(o, scope, s, decision, base)
    end
  end

  defp build(o, {chapter, _, _}, %{kind: "timing"} = s, {:accept, id}, base) do
    case o.tasks[{chapter, s.tenant_id, s.project_id, s.task_id}] do
      nil ->
        {:error, :unknown_task}

      task ->
        {:ok, "TaskTimingRevisedV1",
         Map.merge(base, %{
           "task_id" => s.task_id,
           "expected_timing_version" => task.timing_version,
           "timing" => s.change["timing"],
           "suggestion_event_id" => id
         })}
    end
  end

  defp build(_o, _scope, %{kind: "create"} = s, {:accept, id}, base) do
    {:ok, "TaskCreatedV1",
     base
     |> Map.merge(Map.take(s.change, ~w(title timing description)))
     |> Map.merge(%{"task_id" => s.task_id, "suggestion_event_id" => id})}
  end

  defp build(_o, _scope, _s, {:decline, id, reason}, base),
    do:
      {:ok, "TaskSuggestionDeclinedV1",
       Map.merge(base, %{"suggestion_event_id" => id, "reason" => reason})}

  defp pending(o, {chapter, tenant, project}, id) do
    case o.suggestions[id] do
      %{chapter_id: ^chapter, tenant_id: ^tenant, project_id: ^project, status: :pending} = s ->
        {:ok, s}

      %{chapter_id: ^chapter, tenant_id: ^tenant, project_id: ^project} ->
        {:error, :suggestion_not_pending}

      _ ->
        {:error, :unknown_suggestion}
    end
  end
end
