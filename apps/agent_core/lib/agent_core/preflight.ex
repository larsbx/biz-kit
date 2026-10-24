defmodule AgentCore.Preflight do
  @moduledoc """
  Pure engine-neutral dispatch preparation for a **trusted host**.

  Input `run` must be the fresh result of TaskCore.AgentRuns.runnable?/2,
  never a request body received from an agent. The caller separately checks
  current biz-kit task-read/run authority, agent identity, tenant, consent,
  profile publishing authority and resource quota before dispatch.

  The pure output is an immutable *candidate* execution plan. It is not a
  lease, sandbox request, authorization token, permission to call a tool or
  proof that any agent actually executed. A separate durable coordinator must
  atomically claim the effect ID and re-check ledger revocation prior to launch
  and result admission.
  """

  alias AgentCore.{Capabilities, Profiles}

  @segment ~r/\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\z/
  @ticket_keys ~w(chapter_id tenant_id project_id task_id task_version source_event_id definition_digest)
  @max_duration_ms 31 * 86_400_000
  @max_output_bytes 16 * 1_048_576

  @doc """
  Verify a signed run/profile and required capabilities, without side effects.

  The host must derive `requirements` from trusted task/data-classification
  policy and an authenticated actor, not from agent self-attestation.
  """
  @spec prepare(map(), map(), (map() -> binary()), map()) ::
          {:ok, map()} | {:error, atom()}
  def prepare(run, registry, hash_manifest, requirements)
      when is_map(run) and is_map(requirements) do
    with :ok <- valid_run(run),
         :ok <- budgets_match(run, requirements),
         {:ok, profile} <- Profiles.resolve(run, registry, hash_manifest),
         :ok <- Capabilities.check(profile.manifest, requirements) do
      {:ok,
       %{
         effect_id: "agent-run:" <> run.intent_event_id,
         intent_event_id: run.intent_event_id,
         run_id: run.run_id,
         chapter_id: run.ticket["chapter_id"],
         tenant_id: run.ticket["tenant_id"],
         project_id: run.ticket["project_id"],
         execution_profile_id: run.execution_profile_id,
         execution_profile_digest: run.execution_profile_digest,
         adapter: profile.adapter,
         profile: profile,
         execution: %{
           run_id: run.run_id,
           ticket: run.ticket
         },
         requirements: requirements
       }}
    end
  end

  def prepare(_run, _registry, _hash_manifest, _requirements),
    do: {:error, :invalid_agent_preflight}

  defp valid_run(%{
         run_id: id,
         intent_event_id: intent,
         ticket: ticket,
         execution_profile_id: profile_id,
         execution_profile_digest: {:bytes, <<_::256>>},
         max_duration_ms: duration,
         max_output_bytes: output
       }) do
    if segment?(id) and segment?(intent) and segment?(profile_id) and
         valid_ticket?(ticket) and integer_between?(duration, 1, @max_duration_ms) and
         integer_between?(output, 1, @max_output_bytes),
       do: :ok,
       else: {:error, :invalid_agent_run_preflight}
  end

  defp valid_run(_run), do: {:error, :invalid_agent_run_preflight}

  defp valid_ticket?(t) when is_map(t) do
    Enum.sort(Map.keys(t)) == Enum.sort(@ticket_keys) and
      Enum.all?(~w(chapter_id tenant_id project_id task_id source_event_id), &segment?(t[&1])) and
      integer_between?(t["task_version"], 1, 2_147_483_647) and
      is_binary(t["definition_digest"]) and
      byte_size(t["definition_digest"]) == 64 and
      Regex.match?(~r/\A[0-9a-f]{64}\z/, t["definition_digest"])
  end

  defp valid_ticket?(_ticket), do: false

  defp budgets_match(run, requirements) do
    if requirements["max_duration_ms"] == run.max_duration_ms and
         requirements["max_output_bytes"] == run.max_output_bytes,
       do: :ok,
       else: {:error, :agent_budget_not_bound_to_intent}
  end

  defp segment?(v), do: is_binary(v) and Regex.match?(@segment, v)
  defp integer_between?(v, min, max) when is_integer(v), do: v >= min and v <= max
  defp integer_between?(_v, _min, _max), do: false
end
