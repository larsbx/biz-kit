defmodule TaskCore.DoD do
  @moduledoc """
  Ledger-backed Definition of Done revisions, evidence references and reviews.

  V1 evidence is a digest claim. V2 additionally binds verified custody receipts;
  availability is rechecked on submission and acceptance, not promised forever. A review attests the reviewer's
  decision on that exact revision/submission. It never completes a task: the
  operator's `TaskCompletedV1` does, citing an accepting review
  (docs/architecture/2026-10-19-execution.md).

  A Definition of Done is defined while a task is proposed. Evidence is
  submitted and reviewed while it is proposed or in progress; starting the
  task clears any earlier submission (`TaskCore.Readiness`), so what completes
  it is evidence of the work.

  A reviewer grant may name the device it was enrolled from (`device_label`,
  docs/architecture/2026-10-19-device-enrolment.md).
  """
  alias TaskCore.State

  @commands ~w(TaskDoDDefinedV1 TaskEvidenceSubmittedV1 TaskEvidenceSubmittedV2 TaskDoDReviewedV1)
  @scope %{"tenant_id" => :string, "project_id" => :string}
  @subject Map.merge(@scope, %{"task_id" => :string, "expected_version" => :int})
  @actor %{"principal_id" => :string, "authorization_event_id" => :string}

  def event_types do
    grant =
      Map.merge(@scope, %{"principal_id" => :string, "key_id" => :string, "pubkey" => :pubkey})

    %{
      "TaskReviewerGrantedV1" =>
        spec("governance", "task_reviewers", grant, false, %{"device_label" => :string}),
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
      "ArtifactCustodyRecordedV1" =>
        spec(
          "operator",
          "artifact_custody",
          Map.merge(Map.merge(@scope, @actor), %{"artifact_digest" => :hash}),
          false
        ),
      "TaskEvidenceSubmittedV2" =>
        spec(
          "operator",
          "tasks",
          Map.merge(Map.merge(@subject, @actor), %{
            "definition_event_id" => :string,
            "evidence" => :any,
            "custody_receipts" => :any
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

  defp spec(role, prefix, fields, task?, optional \\ %{}) do
    %{
      required_roles: [role],
      disclosure_class: :edges,
      stream:
        {:payload_fields, prefix,
         if(task?, do: ~w(tenant_id project_id task_id), else: ~w(tenant_id project_id))},
      payload: %{required: fields, optional: optional}
    }
  end

  @doc "The Definition of Done commands a person signs."
  def commands, do: @commands

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
  def check(%{type: "TaskReviewerGrantedV1", payload: p} = env, state, keys) do
    with :ok <- governance(env, keys),
         true <- (text?(p["principal_id"]) and text?(p["key_id"])) or {:error, :empty_task_field},
         true <-
           p["device_label"] == nil or String.length(p["device_label"]) in 1..80 or
             {:error, :invalid_device_label} do
      if Map.has_key?(state.dod_grants, env.event_id),
        do: {:error, :grant_already_recorded},
        else: :ok
    end
  end

  def check(%{type: "TaskReviewerRevokedV1", payload: p} = env, state, keys) do
    with :ok <- governance(env, keys),
         {:ok, grant} <- reviewer_grant(state, p["authorization_event_id"]),
         :ok <- grant_scope(env, grant) do
      if grant.active, do: :ok, else: {:error, :grant_already_revoked}
    end
  end

  def check(%{type: "TaskDoDDefinedV1", payload: p} = env, state, keys) do
    with :ok <- governance(env, keys),
         {:ok, _task} <- current_task(env, state),
         :ok <- validate_criteria(p["criteria"]),
         do: :ok
  end

  def check(%{type: "ArtifactCustodyRecordedV1", payload: p} = env, state, _keys) do
    with {:ok, grant} <-
           fetch_grant(state.grants, p["authorization_event_id"], :unknown_task_grant),
         :ok <- authorized(env, grant),
         true <-
           not Map.has_key?(state.custody_receipts, env.event_id) or
             {:error, :custody_id_conflict},
         {:ok, _bytes} <-
           state.host.verify_artifact(elem(p["artifact_digest"], 1), 8 * 1024 * 1024),
         do: :ok
  end

  def check(%{type: "TaskEvidenceSubmittedV2"} = env, state, _keys) do
    with :ok <- check_submission(env, state),
         :ok <- verified_receipts(env, state),
         do: :ok
  end

  def check(%{type: "TaskEvidenceSubmittedV1"}, _state, _keys),
    do: {:error, :custody_receipts_required}

  def check(%{type: "TaskDoDReviewedV1", payload: p} = env, state, _keys) do
    with {:ok, grant} <- reviewer_grant(state, p["authorization_event_id"]),
         :ok <- authorized(env, grant),
         {:ok, task} <- current_task(env, state),
         :ok <- revision(task, p),
         :ok <- review_availability(env, task, state) do
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

  defp check_submission(%{payload: p} = env, state) do
    with {:ok, grant} <-
           fetch_grant(state.grants, p["authorization_event_id"], :unknown_task_grant),
         :ok <- authorized(env, grant),
         {:ok, task} <- current_task(env, state),
         :ok <- revision(task, p),
         :ok <- validate_evidence(task.dod.criteria, p["evidence"]),
         do: :ok
  end

  defp review_availability(%{payload: p} = env, task, state) do
    submission = task.dod.submission

    if p["decision"] == "accept" and submission != nil and
         submission.event_id == p["submission_event_id"] and
         Map.has_key?(submission, :custody_receipts) do
      verified_receipts(
        %{
          env
          | payload:
              Map.merge(p, %{
                "evidence" => submission.evidence,
                "custody_receipts" => submission.custody_receipts
              })
        },
        state
      )
    else
      :ok
    end
  end

  defp verified_receipts(%{payload: p} = env, state) do
    receipts = p["custody_receipts"]

    if is_map(receipts) and Enum.sort(Map.keys(receipts)) == Enum.sort(Map.keys(p["evidence"])) do
      Enum.reduce_while(receipts, {:ok, 16 * 1024 * 1024}, fn {criterion, id}, {:ok, budget} ->
        result =
          with {:ok, receipt} <- fetch_grant(state.custody_receipts, id, :unknown_custody_receipt),
               :ok <- grant_scope(env, receipt),
               true <-
                 receipt.digest == p["evidence"][criterion] or {:error, :custody_digest_mismatch},
               {:ok, size} <-
                 state.host.verify_artifact(
                   elem(receipt.digest, 1),
                   min(budget, 8 * 1024 * 1024)
                 ),
               do: {:ok, budget - size}

        case result do
          {:ok, remaining} -> {:cont, {:ok, remaining}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, _remaining} -> :ok
        error -> error
      end
    else
      {:error, :invalid_custody_receipts}
    end
  end

  defp current_task(env, state) do
    case Map.fetch(state.tasks, State.task_key(env)) do
      :error ->
        {:error, :unknown_task}

      {:ok, task} ->
        cond do
          env.payload["expected_version"] != task.version ->
            {:error, {:stale_task_version, env.payload["expected_version"], task.version}}

          task.state not in open_states(env.type) ->
            {:error, :dod_task_not_proposed}

          true ->
            {:ok, task}
        end
    end
  end

  # A definition is fixed once the task leaves `proposed`; evidence and its
  # review are of the work once it is under way.
  defp open_states("TaskDoDDefinedV1"), do: ["proposed"]
  defp open_states(_type), do: ["proposed", "in_progress"]

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

  defp governance(%{signers: [signer]} = env, keys) do
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

  defp authorized(%{signers: [signer], payload: p} = env, grant) do
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
  def handle_event(%{type: "TaskReviewerGrantedV1", payload: p} = env, state) do
    grant = %{
      chapter_id: env.chapter_id,
      tenant_id: p["tenant_id"],
      project_id: p["project_id"],
      principal_id: p["principal_id"],
      key_id: p["key_id"],
      pubkey: elem(p["pubkey"], 1),
      device_label: p["device_label"],
      active: true
    }

    put_in(state, [:dod_grants, Access.key(env.event_id)], grant)
  end

  def handle_event(%{type: "TaskReviewerRevokedV1", payload: p}, state),
    do: put_in(state, [:dod_grants, p["authorization_event_id"], :active], false)

  def handle_event(%{type: "ArtifactCustodyRecordedV1", payload: p} = env, state) do
    receipt = %{
      chapter_id: env.chapter_id,
      tenant_id: p["tenant_id"],
      project_id: p["project_id"],
      digest: p["artifact_digest"],
      principal_id: p["principal_id"],
      authorization_event_id: p["authorization_event_id"]
    }

    state
    |> put_in([:custody_receipts, Access.key(env.event_id)], receipt)
    |> put_in([:dod_commands, Access.key(env.event_id)], env)
  end

  def handle_event(%{type: type} = env, state) when type in @commands do
    state
    |> update_in([:tasks, State.task_key(env)], fn task ->
      %{
        task
        | dod: fold_dod(env, task.dod, state.host),
          version: task.version + 1,
          last_event_id: env.event_id
      }
    end)
    |> put_in([:dod_commands, Access.key(env.event_id)], env)
  end

  def handle_event(_, state), do: state

  # A definition is referenced by the host's canonical hash of its criteria.
  defp fold_dod(%{type: "TaskDoDDefinedV1", payload: p} = env, _, host) do
    %{
      event_id: env.event_id,
      criteria: p["criteria"],
      definition_ref: {:bytes, host.hash(p["criteria"])},
      submission: nil,
      review: nil
    }
  end

  defp fold_dod(env, dod, _host), do: fold_dod(env, dod)

  defp fold_dod(
         %{type: "TaskEvidenceSubmittedV1", payload: p, signers: [signer]} = env,
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

  defp fold_dod(%{type: "TaskEvidenceSubmittedV2", payload: p} = env, dod) do
    folded = fold_dod(%{env | type: "TaskEvidenceSubmittedV1"}, dod)
    put_in(folded, [:submission, Access.key(:custody_receipts)], p["custody_receipts"])
  end

  defp fold_dod(%{type: "TaskDoDReviewedV1", payload: p} = env, dod) do
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
