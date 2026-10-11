defmodule CoopSubstrate.Tasks.DoD do
  @moduledoc """
  Ledger-backed Definition of Done revisions, evidence references and reviews.

  Evidence is a signed claim linking each criterion to an artifact digest, not
  proof of artifact custody or correctness. A review attests the reviewer's
  decision on that exact revision/submission. It never completes a task.
  """
  alias CoopSubstrate.{Canonical, Log}
  alias CoopSubstrate.Protocol.Envelope
  alias CoopSubstrate.Projections.Tasks, as: Projection

  @commands ~w(TaskDoDDefinedV1 TaskEvidenceSubmittedV1 TaskDoDReviewedV1)
  @scope %{"tenant_id" => :string, "project_id" => :string}
  @subject Map.merge(@scope, %{"task_id" => :string, "expected_version" => :int})
  @actor %{"principal_id" => :string, "authorization_event_id" => :string}

  def event_types do
    grant =
      Map.merge(@scope, %{"principal_id" => :string, "key_id" => :string, "pubkey" => :pubkey})

    %{
      "TaskReviewerGrantedV1" => spec("governance", "task_reviewers", grant, false),
      "TaskReviewerRevokedV1" =>
        spec(
          "governance",
          "task_reviewers",
          Map.put(@scope, "authorization_event_id", :string),
          false
        ),
      "TaskDoDDefinedV1" =>
        spec("governance", "tasks", Map.put(@subject, "criteria", :any), true),
      "TaskEvidenceSubmittedV1" =>
        spec(
          "operator",
          "tasks",
          Map.merge(Map.merge(@subject, @actor), %{
            "definition_event_id" => :string,
            "evidence" => :any
          }),
          true
        ),
      "TaskDoDReviewedV1" =>
        spec(
          "reviewer",
          "tasks",
          Map.merge(Map.merge(@subject, @actor), %{
            "definition_event_id" => :string,
            "submission_event_id" => :string,
            "decision" => :string,
            "reason" => :string
          }),
          true
        )
    }
  end

  defp spec(role, prefix, fields, task?) do
    %{
      required_roles: [role],
      disclosure_class: :edges,
      stream:
        {:payload_fields, prefix,
         if(task?, do: ~w(tenant_id project_id task_id), else: ~w(tenant_id project_id))},
      payload: %{required: fields, optional: %{}}
    }
  end

  def submit(command, server \\ Log)

  def submit(%Envelope{type: type} = command, server) when type in @commands do
    with {:ok, [accepted]} <- Log.append(command, server),
         {:ok, hash} <- Envelope.event_hash(accepted) do
      {:ok,
       %{
         event_id: accepted.event_id,
         event_hash: hash,
         global_seq: accepted.global_seq,
         task_version: accepted.payload["expected_version"] + 1
       }}
    end
  end

  def submit(_, _), do: {:error, :not_a_dod_command}

  def validate_criteria(criteria) when is_list(criteria) and length(criteria) in 1..32 do
    valid =
      Enum.all?(criteria, fn
        %{"id" => id, "description" => description} = c when map_size(c) == 2 ->
          segment?(id) and text?(description)

        _ ->
          false
      end)

    ids = Enum.map(criteria, fn c -> if is_map(c), do: c["id"], else: nil end)

    if valid and length(Enum.uniq(ids)) == length(ids),
      do: :ok,
      else: {:error, :invalid_dod_criteria}
  end

  def validate_criteria(_), do: {:error, :invalid_dod_criteria}

  def validate_evidence(criteria, evidence) when is_map(evidence) do
    with :ok <- validate_criteria(criteria),
         true <- Enum.sort(Map.keys(evidence)) == Enum.sort(Enum.map(criteria, & &1["id"])),
         true <- Enum.all?(Map.values(evidence), &match?({:bytes, <<_::256>>}, &1)) do
      :ok
    else
      _ -> {:error, :invalid_dod_evidence}
    end
  end

  def validate_evidence(_, _), do: {:error, :invalid_dod_evidence}

  @doc false
  def check(%Envelope{type: "TaskReviewerGrantedV1", payload: p} = env, state, keys) do
    with :ok <- governance(env, keys),
         true <- (text?(p["principal_id"]) and text?(p["key_id"])) or {:error, :empty_task_field} do
      if Map.has_key?(state.dod_grants, env.event_id),
        do: {:error, :grant_already_recorded},
        else: :ok
    end
  end

  def check(%Envelope{type: "TaskReviewerRevokedV1", payload: p} = env, state, keys) do
    with :ok <- governance(env, keys),
         {:ok, grant} <- reviewer_grant(state, p["authorization_event_id"]),
         :ok <- grant_scope(env, grant) do
      if grant.active, do: :ok, else: {:error, :grant_already_revoked}
    end
  end

  def check(%Envelope{type: "TaskDoDDefinedV1", payload: p} = env, state, keys) do
    with :ok <- governance(env, keys),
         {:ok, _task} <- current_task(env, state),
         :ok <- validate_criteria(p["criteria"]),
         do: :ok
  end

  def check(%Envelope{type: "TaskEvidenceSubmittedV1", payload: p} = env, state, _keys) do
    with {:ok, grant} <-
           fetch_grant(state.grants, p["authorization_event_id"], :unknown_task_grant),
         :ok <- authorized(env, grant),
         {:ok, task} <- current_task(env, state),
         :ok <- revision(task, p),
         :ok <- validate_evidence(task.dod.criteria, p["evidence"]),
         do: :ok
  end

  def check(%Envelope{type: "TaskDoDReviewedV1", payload: p} = env, state, _keys) do
    with {:ok, grant} <- reviewer_grant(state, p["authorization_event_id"]),
         :ok <- authorized(env, grant),
         {:ok, task} <- current_task(env, state),
         :ok <- revision(task, p) do
      submission = task.dod.submission
      [signer] = env.signers

      cond do
        submission == nil or submission.event_id != p["submission_event_id"] ->
          {:error, :dod_submission_mismatch}

        task.dod.review != nil ->
          {:error, :dod_already_reviewed}

        submission.principal_id == p["principal_id"] or submission.pubkey == signer.pubkey ->
          {:error, :dod_self_review}

        p["decision"] not in ["accept", "refuse"] or not text?(p["reason"]) ->
          {:error, :invalid_dod_review}

        true ->
          :ok
      end
    end
  end

  defp current_task(env, state) do
    case Map.fetch(state.tasks, Projection.task_key(env)) do
      :error ->
        {:error, :unknown_task}

      {:ok, task} ->
        cond do
          env.payload["expected_version"] != task.version ->
            {:error, {:stale_task_version, env.payload["expected_version"], task.version}}

          task.state != "proposed" ->
            {:error, :dod_task_not_proposed}

          true ->
            {:ok, task}
        end
    end
  end

  defp revision(%{dod: nil}, _), do: {:error, :dod_not_defined}

  defp revision(task, p) do
    if task.dod.event_id == p["definition_event_id"],
      do: :ok,
      else: {:error, :dod_revision_mismatch}
  end

  defp reviewer_grant(state, id), do: fetch_grant(state.dod_grants, id, :unknown_reviewer_grant)

  defp fetch_grant(grants, id, error) do
    case Map.fetch(grants, id) do
      {:ok, grant} -> {:ok, grant}
      :error -> {:error, error}
    end
  end

  defp governance(%Envelope{signers: [signer]} = env, keys) do
    if get_in(keys, [{env.chapter_id, "governance"}, signer.key_id]) == signer.pubkey,
      do: :ok,
      else: {:error, :task_governance_not_declared}
  end

  defp grant_scope(env, grant) do
    if {env.chapter_id, env.payload["tenant_id"], env.payload["project_id"]} ==
         {grant.chapter_id, grant.tenant_id, grant.project_id},
       do: :ok,
       else: {:error, :task_grant_scope_mismatch}
  end

  defp authorized(%Envelope{signers: [signer], payload: p} = env, grant) do
    with :ok <- grant_scope(env, grant) do
      cond do
        not grant.active ->
          {:error, :task_grant_revoked}

        p["principal_id"] != grant.principal_id ->
          {:error, :task_principal_mismatch}

        {signer.key_id, signer.pubkey} != {grant.key_id, grant.pubkey} ->
          {:error, :task_operator_key_mismatch}

        true ->
          :ok
      end
    end
  end

  defp segment?(value),
    do:
      is_binary(value) and byte_size(value) in 1..128 and
        Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/, value)

  defp text?(value),
    do:
      is_binary(value) and String.valid?(value) and byte_size(value) in 1..2048 and
        String.trim(value) != ""

  @doc false
  def handle_event(%Envelope{type: "TaskReviewerGrantedV1", payload: p} = env, state) do
    grant = %{
      chapter_id: env.chapter_id,
      tenant_id: p["tenant_id"],
      project_id: p["project_id"],
      principal_id: p["principal_id"],
      key_id: p["key_id"],
      pubkey: elem(p["pubkey"], 1),
      active: true
    }

    put_in(state, [:dod_grants, Access.key(env.event_id)], grant)
  end

  def handle_event(%Envelope{type: "TaskReviewerRevokedV1", payload: p}, state),
    do: put_in(state, [:dod_grants, p["authorization_event_id"], :active], false)

  def handle_event(%Envelope{type: type} = env, state) when type in @commands do
    state
    |> update_in([:tasks, Projection.task_key(env)], fn task ->
      %{
        task
        | dod: fold_dod(env, task.dod),
          version: task.version + 1,
          last_event_id: env.event_id
      }
    end)
    |> put_in([:dod_commands, Access.key(env.event_id)], env)
  end

  def handle_event(_, state), do: state

  defp fold_dod(%Envelope{type: "TaskDoDDefinedV1", payload: p} = env, _) do
    %{
      event_id: env.event_id,
      criteria: p["criteria"],
      definition_ref: {:bytes, Canonical.hash!(p["criteria"])},
      submission: nil,
      review: nil
    }
  end

  defp fold_dod(
         %Envelope{type: "TaskEvidenceSubmittedV1", payload: p, signers: [signer]} = env,
         dod
       ) do
    %{
      dod
      | submission: %{
          event_id: env.event_id,
          principal_id: p["principal_id"],
          pubkey: signer.pubkey,
          evidence: p["evidence"]
        },
        review: nil
    }
  end

  defp fold_dod(%Envelope{type: "TaskDoDReviewedV1", payload: p} = env, dod) do
    %{
      dod
      | review: %{
          event_id: env.event_id,
          principal_id: p["principal_id"],
          submission_event_id: p["submission_event_id"],
          decision: p["decision"],
          reason: p["reason"]
        }
    }
  end
end
