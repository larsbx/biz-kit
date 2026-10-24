defmodule TaskCore.AgentCandidates do
  @moduledoc """
  Pure, *non-authoritative* TaskCore -> sandbox candidate handoff.

  A trusted host supplies a CURRENT, committed TaskCore replay, and separately
  authorizes task reads. This module does not verify signatures, authorize
  reads, store runs, or append commands. In particular, a suggester grant
  permits suggestions, not general access to private task content.

  The returned map matches the small ticket accepted by the experimental
  OpenShell Python runner. It contains no task body, credential or authority
  token. A caller MUST check freshness again after execution, and any actual
  business command must pass the signed, serialized CoopSubstrate append gate.
  """

  alias TaskCore.Admission

  @fields ~w(chapter_id tenant_id project_id task_id principal_id suggester_grant_event_id)a
  @open_states ~w(ready in_progress)
  @max_version 2_147_483_647

  @doc """
  Construct an inert sandbox ticket from trusted TaskCore replay.

  A live project-scoped suggester grant is required to bind the agent principal.
  This is only one prerequisite: the host must independently authorize the
  assignment, disclose no private task fields without a read grant, and enforce
  its execution budget and policy. No change to task state occurs here.
  """
  @spec plan(map(), map()) :: {:ok, map()} | {:error, atom()}
  def plan(%{tasks: tasks, suggester_grants: grants}, request)
      when is_map(tasks) and is_map(grants) and is_map(request) do
    with :ok <- valid_request(request),
         {:ok, grant} <- fetch(grants, request.suggester_grant_event_id, :unknown_agent_grant),
         :ok <- grant_valid(grant, request),
         {:ok, task} <- fetch(tasks, task_key(request), :unknown_task),
         {:ok, digest} <- eligible_task(task) do
      {:ok,
       %{
         "chapter_id" => request.chapter_id,
         "tenant_id" => request.tenant_id,
         "project_id" => request.project_id,
         "task_id" => request.task_id,
         "task_version" => task.version,
         "source_event_id" => task.last_event_id,
         "definition_digest" => digest
       }}
    end
  end

  def plan(_state, _request), do: {:error, :invalid_replay_or_request}

  @doc """
  Recheck a prior ticket after a sandbox run against CURRENT trusted replay.

  Passing this check never approves a candidate or completes the task. It only
  rejects stale revisions and revoked grants before the result is considered
  for separately authorized proposal/evidence processing.
  """
  @spec current?(map(), map(), map()) :: :ok | {:error, atom()}
  def current?(state, request, ticket) when is_map(ticket) do
    case plan(state, request) do
      {:ok, ^ticket} -> :ok
      {:ok, _newer} -> {:error, :stale_agent_ticket}
      {:error, _} = error -> error
    end
  end

  def current?(_state, _request, _ticket), do: {:error, :invalid_agent_ticket}

  defp valid_request(request) do
    if Enum.sort(Map.keys(request)) == Enum.sort(@fields) and
         Enum.all?(@fields, fn field -> Admission.segment?(Map.get(request, field)) end),
       do: :ok,
       else: {:error, :invalid_agent_request}
  end

  defp task_key(r), do: {r.chapter_id, r.tenant_id, r.project_id, r.task_id}

  defp grant_valid(
         %{active: true, principal_id: principal, chapter_id: chapter, tenant_id: tenant,
           project_id: project},
         r
       ) do
    if {principal, chapter, tenant, project} ==
         {r.principal_id, r.chapter_id, r.tenant_id, r.project_id},
       do: :ok,
       else: {:error, :agent_grant_scope_or_identity_mismatch}
  end

  defp grant_valid(%{active: false}, _request), do: {:error, :agent_grant_revoked}
  defp grant_valid(_grant, _request), do: {:error, :invalid_agent_grant}

  defp eligible_task(%{
         state: state,
         version: version,
         last_event_id: source,
         dod: %{definition_ref: {:bytes, digest}}
       })
       when state in @open_states and is_integer(version) and
              version >= 1 and version <= @max_version and
              is_binary(digest) and byte_size(digest) == 32 do
    if Admission.segment?(source),
      do: {:ok, Base.encode16(digest, case: :lower)},
      else: {:error, :invalid_task_source}
  end

  defp eligible_task(%{state: state}) when state not in @open_states,
    do: {:error, :task_not_ready_for_agent}

  defp eligible_task(_task), do: {:error, :task_definition_missing_or_invalid}

  defp fetch(map, key, error) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, error}
    end
  end
end
