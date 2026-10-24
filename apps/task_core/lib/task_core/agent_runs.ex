defmodule TaskCore.AgentRuns do
  @moduledoc """
  Signed **run intent** for agents; not a sandbox job queue or a second writer.

  TaskAgentRunRequestedV1 is an operator-signed, serialized ledger fact binding
  a run to the current task version, last event, DoD, and a named agent holding
  an active project-scoped suggester grant. It names a portable execution
  profile ID and immutable profile digest, never a specific engine, model,
  container, image, policy implementation, or vendor. Profile resolution
  and runtime selection are separate, authenticated host responsibilities.
  Admission NEVER grants task-read, execution, or tool-write privileges.
  A suggester grant is only a prerequisite for this operator request.

  TaskAgentRunCancelledV1 is an operator-signed withdrawal. The execution
  adapter must repeatedly recheck runnable?/2 against fresh committed ledger
  state; even a previously accepted run cannot bypass grant revocation.
  Successful agent outputs are candidates, not DoD evidence or completion.
  """

  alias TaskCore.{Admission, AgentCandidates, State}

  @scope %{"tenant_id" => :string, "project_id" => :string}
  @run Map.merge(@scope, %{"run_id" => :string})
  @actor %{"principal_id" => :string, "authorization_event_id" => :string}
  @max_runtime_ms 15 * 60_000
  @max_result_bytes 65_536

  def event_types do
    %{
      "TaskAgentRunRequestedV1" =>
        spec(
          Map.merge(@run, %{
            "task_id" => :string,
            "agent_principal_id" => :string,
            "suggester_grant_event_id" => :string,
            "expected_task_version" => :int,
            "source_event_id" => :string,
            "definition_digest" => :hash,
            "execution_profile_id" => :string,
            "execution_profile_digest" => :hash,
            "max_duration_ms" => :int,
            "max_output_bytes" => :int,
            "lifecycle_version" => :int
          })
          |> Map.merge(@actor)
        ),
      "TaskAgentRunCancelledV1" =>
        spec(
          Map.merge(@run, %{
            "expected_run_version" => :int,
            "reason" => :string
          })
          |> Map.merge(@actor)
        )
    }
  end

  defp spec(fields) do
    %{
      required_roles: ["operator"],
      disclosure_class: :edges,
      stream: {:payload_fields, "task_agent_runs", ~w(tenant_id project_id run_id)},
      payload: %{required: fields, optional: %{}}
    }
  end

  def init, do: %{agent_runs: %{}, agent_run_commands: %{}}

  def check(%{type: "TaskAgentRunRequestedV1", payload: p} = env, state) do
    with :ok <- authorized_operator(env, state),
         :ok <- valid_request_fields(p),
         :ok <- vacant_run(env, state),
         {:ok, candidate} <- AgentCandidates.plan(state, agent_request(env)),
         :ok <- matched_ticket(candidate, p) do
      :ok
    end
  end

  def check(%{type: "TaskAgentRunCancelledV1", payload: p} = env, state) do
    with :ok <- authorized_operator(env, state),
         :ok <- validate_cancel_fields(p),
         :ok <- validate_reason(p["reason"]),
         {:ok, run} <- fetch(state.agent_runs, run_key(env), :unknown_agent_run) do
      cond do
        run.status != :requested -> {:error, :agent_run_already_cancelled}
        p["expected_run_version"] != run.version -> {:error, :stale_agent_run_version}
        true -> :ok
      end
    end
  end

  defp authorized_operator(%{payload: p} = env, state) do
    with {:ok, grant} <- fetch(state.grants, p["authorization_event_id"], :unknown_task_grant),
         do: Admission.authorized(env, grant)
  end

  defp valid_request_fields(p) do
    checks = [
      p["lifecycle_version"] == 1,
      Enum.all?(~w(run_id task_id agent_principal_id suggester_grant_event_id
                     source_event_id execution_profile_id), &Admission.segment?(p[&1])),
      p["expected_task_version"] in 1..2_147_483_647,
      p["max_duration_ms"] in 1_000..@max_runtime_ms,
      p["max_output_bytes"] in 1..@max_result_bytes,
      hash?(p["definition_digest"]),
      hash?(p["execution_profile_digest"])
    ]

    if Enum.all?(checks), do: :ok, else: {:error, :invalid_agent_run_request}
  end

  defp hash?({:bytes, <<_::256>>}), do: true
  defp hash?(_value), do: false

  defp vacant_run(env, state) do
    if Map.has_key?(state.agent_runs, run_key(env)),
      do: {:error, :agent_run_id_already_used},
      else: :ok
  end

  defp validate_cancel_fields(p) do
    if Admission.segment?(p["run_id"]) and
         is_integer(p["expected_run_version"]) and p["expected_run_version"] >= 1,
      do: :ok,
      else: {:error, :invalid_agent_run_cancellation}
  end

  defp validate_reason(value) when is_binary(value) do
    if String.valid?(value) and byte_size(value) in 1..512 and String.trim(value) != "",
      do: :ok,
      else: {:error, :invalid_agent_run_cancellation_reason}
  end

  defp validate_reason(_value), do: {:error, :invalid_agent_run_cancellation_reason}

  defp agent_request(%{chapter_id: chapter, payload: p}) do
    %{
      chapter_id: chapter,
      tenant_id: p["tenant_id"],
      project_id: p["project_id"],
      task_id: p["task_id"],
      principal_id: p["agent_principal_id"],
      suggester_grant_event_id: p["suggester_grant_event_id"]
    }
  end

  defp matched_ticket(ticket, p) do
    expected = %{
      "task_version" => p["expected_task_version"],
      "source_event_id" => p["source_event_id"],
      "definition_digest" => Base.encode16(elem(p["definition_digest"], 1), case: :lower)
    }

    if Enum.all?(expected, fn {key, val} -> ticket[key] == val end),
      do: :ok,
      else: {:error, :stale_agent_run_task}
  end

  defp run_key(%{chapter_id: chapter, payload: p}),
    do: {chapter, p["tenant_id"], p["project_id"], p["run_id"]}

  def handle_event(%{type: "TaskAgentRunRequestedV1", payload: p} = env, state) do
    run = %{
      status: :requested,
      version: 1,
      intent_event_id: env.event_id,
      operator_grant_id: p["authorization_event_id"],
      agent_principal_id: p["agent_principal_id"],
      suggester_grant_event_id: p["suggester_grant_event_id"],
      task_id: p["task_id"],
      expected_task_version: p["expected_task_version"],
      source_event_id: p["source_event_id"],
      definition_digest: p["definition_digest"],
      execution_profile_id: p["execution_profile_id"],
      execution_profile_digest: p["execution_profile_digest"],
      max_duration_ms: p["max_duration_ms"],
      max_output_bytes: p["max_output_bytes"]
    }

    state
    |> put_in([:agent_runs, Access.key(run_key(env))], run)
    |> put_in([:agent_run_commands, Access.key(env.event_id)], env)
  end

  def handle_event(%{type: "TaskAgentRunCancelledV1"} = env, state) do
    state
    |> update_in([:agent_runs, run_key(env)], &%{&1 | status: :cancelled, version: &1.version + 1})
    |> put_in([:agent_run_commands, Access.key(env.event_id)], env)
  end

  def handle_event(_env, state), do: state

  @doc """
  Revalidate an existing run against current committed task/authority state.

  Returns a minimal ticket and portable execution-profile reference for a
  separately authorized coordinator. A host must resolve the exact signed
  profile digest to a current approved profile and independently authorize
  execution/read/tool access. No runtime is selected here.
  """
  def runnable?(state, {chapter, tenant, project, run_id} = key) do
    with {:ok, run} <- fetch(state.agent_runs, key, :unknown_agent_run),
         :ok <- run_open(run),
         {:ok, grant} <- fetch(state.grants, run.operator_grant_id, :unknown_task_grant),
         :ok <- active_operator(grant, {chapter, tenant, project}),
         {:ok, ticket} <-
           AgentCandidates.plan(state, %{
             chapter_id: chapter,
             tenant_id: tenant,
             project_id: project,
             task_id: run.task_id,
             principal_id: run.agent_principal_id,
             suggester_grant_event_id: run.suggester_grant_event_id
           }),
         :ok <- matched_ticket(ticket, %{
           "expected_task_version" => run.expected_task_version,
           "source_event_id" => run.source_event_id,
           "definition_digest" => run.definition_digest
         }) do
      {:ok,
       %{
         ticket: ticket,
         intent_event_id: run.intent_event_id,
         execution_profile_id: run.execution_profile_id,
         execution_profile_digest: run.execution_profile_digest,
         max_duration_ms: run.max_duration_ms,
         max_output_bytes: run.max_output_bytes
       }}
    end
  end

  def runnable?(_state, _key), do: {:error, :invalid_agent_run_key}

  defp run_open(%{status: :requested}), do: :ok
  defp run_open(_run), do: {:error, :agent_run_cancelled}

  defp active_operator(%{active: true} = grant, {chapter, tenant, project}) do
    if {grant.chapter_id, grant.tenant_id, grant.project_id} == {chapter, tenant, project},
      do: :ok,
      else: {:error, :agent_run_operator_scope_changed}
  end

  defp active_operator(_grant, _scope), do: {:error, :agent_run_operator_revoked}

  defp fetch(map, key, error) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, error}
    end
  end
end
