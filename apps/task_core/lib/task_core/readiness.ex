defmodule TaskCore.Readiness do
  @moduledoc """
  The operator's path proposed -> queued -> ready -> in_progress -> completed.
  Governance commits exact input digests, predecessor IDs and a required SOP
  digest, and queuing requires the task's Definition of Done. Operators
  acknowledge the SOP and request transitions. Replay folds accepted facts
  without filesystem reads or execution effects.

  Execution (docs/architecture/2026-10-19-execution.md):

    * `TaskStartedV1` (ready -> in_progress) rechecks what readiness
      admitted: the starter's own SOP acknowledgement and the input receipts,
      bytes included. It clears any evidence submitted earlier, so what
      completes the task is evidence of this work (`TaskCore.DoD`).
    * `TaskCompletedV1` (in_progress -> completed) cites the review of the
      current submission, which must accept it. A review confers no
      lifecycle authority by itself: an operator completes the task.

  A completed task is what a successor's readiness waits for.

  Cancel and reopen (docs/architecture/2026-10-19-cancel-reopen.md):

    * `TaskCancelledV1`, by an operator before the work starts (inbox,
      proposed, queued or ready), and `TaskCancelledByGovernanceV1`, by a
      governance key from any state short of completed, both with a reason.
      Cancelled is final; a successor that names the task can no longer
      become ready unless governance redefines its predecessors.
    * `TaskReopenedV1` (in_progress -> queued), by an operator with a
      reason: who started it, the evidence and its review are cleared, and
      the task must be readied again.
  """
  alias TaskCore.State
  alias TaskCore.TaskLifecycle

  @commands ~w(TaskReadinessDefinedV1 TaskSOPAcknowledgedV1 TaskQueuedV1 TaskReadyV1
                TaskStartedV1 TaskCompletedV1 TaskCancelledV1 TaskCancelledByGovernanceV1
                TaskReopenedV1)
  @governance ~w(TaskReadinessDefinedV1 TaskCancelledByGovernanceV1)
  @cancels ~w(TaskCancelledV1 TaskCancelledByGovernanceV1)
  @subject %{
    "tenant_id" => :string,
    "project_id" => :string,
    "task_id" => :string,
    "expected_version" => :int
  }
  @actor %{
    "principal_id" => :string,
    "authorization_event_id" => :string,
    "lifecycle_version" => :int
  }

  # Each command's move: the states it may leave, and the state it enters.
  # Each is part of `TaskCore.TaskLifecycle`, checked as this compiles; all of
  # them together are the whole relation (TaskLifecycleMovesTest).
  @moves %{
    "TaskProposedV1" => {~w(inbox), "proposed"},
    "TaskQueuedV1" => {~w(proposed), "queued"},
    "TaskReadyV1" => {~w(queued), "ready"},
    "TaskStartedV1" => {~w(ready), "in_progress"},
    "TaskCompletedV1" => {~w(in_progress), "completed"},
    # Before the work starts, a person may call it off; once under way, only
    # governance may, or the task goes back to be readied again.
    "TaskCancelledV1" => {~w(inbox proposed queued ready), "cancelled"},
    "TaskCancelledByGovernanceV1" => {~w(inbox proposed queued ready in_progress), "cancelled"},
    "TaskReopenedV1" => {~w(in_progress), "queued"}
  }

  for {type, {from, to}} <- @moves,
      state <- from,
      not TaskLifecycle.allowed?(String.to_atom(state), String.to_atom(to)) do
    raise CompileError, description: "#{type}: #{state} -> #{to} is not in TaskCore.TaskLifecycle"
  end

  @doc "Each lifecycle command's move, as `%{type => {from_states, to_state}}`."
  def moves, do: @moves

  @doc "Whether the task's state admits the command's move."
  def move(task, type) do
    {from, to} = Map.fetch!(@moves, type)
    transition(task, from, to)
  end

  def event_types do
    %{
      "TaskReadinessDefinedV1" =>
        spec("governance", %{
          "artifact_requirements" => :any,
          "predecessor_ids" => :any,
          "sop_digest" => :hash
        }),
      "TaskSOPAcknowledgedV1" => spec("operator", Map.put(@actor, "custody_receipt_id", :string)),
      "TaskQueuedV1" => spec("operator", @actor),
      "TaskReadyV1" => spec("operator", Map.put(@actor, "custody_receipts", :any)),
      "TaskStartedV1" => spec("operator", @actor),
      "TaskCompletedV1" => spec("operator", Map.put(@actor, "review_event_id", :string)),
      "TaskCancelledV1" => spec("operator", Map.put(@actor, "reason", :string)),
      "TaskCancelledByGovernanceV1" => spec("governance", %{"reason" => :string}),
      "TaskReopenedV1" => spec("operator", Map.put(@actor, "reason", :string))
    }
  end

  defp spec(role, fields) do
    %{
      required_roles: [role],
      disclosure_class: :edges,
      stream: {:payload_fields, "tasks", ~w(tenant_id project_id task_id)},
      payload: %{required: Map.merge(@subject, fields), optional: %{}}
    }
  end

  def check(%{payload: p} = env, state, keys) do
    with :ok <- authority(env, state, keys),
         {:ok, task} <- current_task(env, state) do
      check_command(env, p, task, state)
    end
  end

  @doc "The cancelling commands (an operator's or governance's)."
  def cancels, do: @cancels

  defp authority(%{type: type, signers: [signer]} = env, _, keys)
       when type in @governance do
    if get_in(keys, [{env.chapter_id, "governance"}, signer.key_id]) == signer.pubkey,
      do: :ok,
      else: {:error, :task_governance_not_declared}
  end

  defp authority(%{payload: p} = env, state, _) do
    with {:ok, grant} <- fetch(state.grants, p["authorization_event_id"], :unknown_task_grant),
         :ok <- TaskCore.Admission.authorized(env, grant) do
      if p["lifecycle_version"] == 1, do: :ok, else: {:error, :unsupported_task_lifecycle}
    end
  end

  defp current_task(env, state) do
    with {:ok, task} <- fetch(state.tasks, State.task_key(env), :unknown_task) do
      if env.payload["expected_version"] == task.version,
        do: {:ok, task},
        else: {:error, {:stale_task_version, env.payload["expected_version"], task.version}}
    end
  end

  defp check_command(%{type: "TaskReadinessDefinedV1"} = env, p, task, state) do
    with :ok <- transition(task, ["proposed", "queued"], "define_readiness"),
         :ok <- requirements(p["artifact_requirements"]),
         :ok <- predecessors(env, p["predecessor_ids"], state),
         :ok <-
           TaskCore.Hierarchy.keeps_blueprint(
             task,
             p["predecessor_ids"],
             p["artifact_requirements"]
           ),
         do: :ok
  end

  defp check_command(%{type: "TaskSOPAcknowledgedV1"} = env, p, task, state) do
    with :ok <- transition(task, ["proposed", "queued", "ready"], "acknowledge_sop"),
         {:ok, definition} <- definition(task),
         {:ok, _} <-
           receipt(env, p["custody_receipt_id"], definition.sop_digest, state, 8 * 1024 * 1024),
         do: :ok
  end

  defp check_command(%{type: "TaskQueuedV1"} = env, _, task, state) do
    with :ok <- move(task, env.type),
         :ok <- dod_defined(task),
         {:ok, _} <- definition(task),
         :ok <- acknowledgment(env, task, state),
         do: :ok
  end

  defp check_command(%{type: "TaskReadyV1"} = env, p, task, state) do
    with :ok <- move(task, env.type),
         {:ok, definition} <- definition(task),
         :ok <- acknowledgment(env, task, state),
         :ok <- completed_predecessors(env, definition.predecessor_ids, state),
         :ok <-
           input_receipts(env, definition.artifact_requirements, p["custody_receipts"], state),
         do: :ok
  end

  # Whoever starts acknowledged the SOP on this device, and the inputs are
  # still there.
  defp check_command(%{type: "TaskStartedV1"} = env, _, task, state) do
    with :ok <- move(task, env.type),
         {:ok, definition} <- definition(task),
         :ok <- acknowledgment(env, task, state),
         :ok <- input_receipts(env, definition.artifact_requirements, task.ready_receipts, state),
         do: :ok
  end

  # A new submission clears the review (`TaskCore.DoD`), so a review on record is
  # of the current submission.
  defp check_command(
         %{type: "TaskCompletedV1" = type},
         %{"review_event_id" => id},
         task,
         _
       ) do
    with :ok <- move(task, type) do
      case task.dod.review do
        %{event_id: ^id, decision: "accept"} -> :ok
        %{event_id: ^id} -> {:error, :dod_not_accepted}
        _ -> {:error, :dod_review_mismatch}
      end
    end
  end

  defp check_command(%{type: type}, p, task, _state)
       when type in ~w(TaskCancelledV1 TaskCancelledByGovernanceV1 TaskReopenedV1) do
    with :ok <- move(task, type), do: reason(p["reason"])
  end

  defp reason(text) do
    if is_binary(text) and String.trim(text) != "" and String.length(text) <= 2048,
      do: :ok,
      else: {:error, :invalid_reason}
  end

  defp transition(task, allowed, to) do
    if task.state in allowed,
      do: :ok,
      else: {:error, {:invalid_task_transition, task.state, to}}
  end

  # A DoD can only be defined while a task is proposed (`TaskCore.DoD`), so queuing
  # without one would leave the task unable ever to get one.
  defp dod_defined(%{dod: nil}), do: {:error, :dod_not_defined}
  defp dod_defined(_task), do: :ok

  defp definition(task) do
    case Map.get(task, :readiness) do
      nil -> {:error, :readiness_not_defined}
      definition -> {:ok, definition}
    end
  end

  defp requirements(value) when is_map(value) and map_size(value) <= 32 do
    if Enum.all?(value, fn {name, digest} ->
         segment?(name) and match?({:bytes, <<_::256>>}, digest)
       end),
       do: :ok,
       else: {:error, :invalid_artifact_requirements}
  end

  defp requirements(_), do: {:error, :invalid_artifact_requirements}

  defp predecessors(env, ids, state) when is_list(ids) and length(ids) <= 32 do
    if Enum.all?(ids, &segment?/1) and Enum.uniq(ids) == ids and env.payload["task_id"] not in ids do
      Enum.reduce_while(ids, :ok, fn id, :ok ->
        case fetch(state.tasks, predecessor_key(env, id), :unknown_predecessor) do
          {:ok, _} -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    else
      {:error, :invalid_predecessors}
    end
  end

  defp predecessors(_, _, _), do: {:error, :invalid_predecessors}

  defp predecessor_key(env, id), do: put_elem(State.task_key(env), 3, id)

  defp completed_predecessors(env, ids, state) do
    if Enum.all?(ids, fn id ->
         match?(%{state: "completed"}, state.tasks[predecessor_key(env, id)])
       end),
       do: :ok,
       else: {:error, :incomplete_predecessors}
  end

  defp acknowledgment(env, task, state) do
    ack = task.readiness.acknowledgment

    if ack != nil and ack.principal_id == env.payload["principal_id"] and
         ack.pubkey == hd(env.signers).pubkey do
      case receipt(env, ack.custody_receipt_id, task.readiness.sop_digest, state, 8 * 1024 * 1024) do
        {:ok, _} -> :ok
        error -> error
      end
    else
      {:error, :sop_acknowledgment_required}
    end
  end

  defp input_receipts(env, requirements, receipts, state) do
    if is_map(receipts) and Enum.sort(Map.keys(receipts)) == Enum.sort(Map.keys(requirements)) do
      Enum.reduce_while(Enum.sort(receipts), {:ok, 16 * 1024 * 1024}, fn {name, id},
                                                                         {:ok, budget} ->
        case receipt(env, id, requirements[name], state, min(budget, 8 * 1024 * 1024)) do
          {:ok, size} -> {:cont, {:ok, budget - size}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, _} -> :ok
        error -> error
      end
    else
      {:error, :invalid_readiness_receipts}
    end
  end

  defp receipt(env, id, digest, state, budget) do
    with {:ok, receipt} <- fetch(state.custody_receipts, id, :unknown_custody_receipt),
         true <-
           {env.chapter_id, env.payload["tenant_id"], env.payload["project_id"]} ==
             {receipt.chapter_id, receipt.tenant_id, receipt.project_id} or
             {:error, :task_grant_scope_mismatch},
         true <- receipt.digest == digest or {:error, :custody_digest_mismatch},
         do: state.host.verify_artifact(elem(digest, 1), budget)
  end

  defp fetch(map, id, reason) do
    case Map.fetch(map, id) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, reason}
    end
  end

  defp segment?(value),
    do:
      is_binary(value) and byte_size(value) in 1..128 and
        Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/, value)

  def handle_event(%{type: type} = env, state) when type in @commands do
    state
    |> update_in([:tasks, State.task_key(env)], fn task ->
      task
      |> fold(env)
      |> Map.put(:version, task.version + 1)
      |> Map.put(:last_event_id, env.event_id)
    end)
    |> put_in([:dod_commands, Access.key(env.event_id)], env)
  end

  def handle_event(_, state), do: state

  defp fold(task, %{type: "TaskReadinessDefinedV1", payload: p} = env) do
    Map.put(task, :readiness, %{
      event_id: env.event_id,
      artifact_requirements: p["artifact_requirements"],
      predecessor_ids: p["predecessor_ids"],
      sop_digest: p["sop_digest"],
      acknowledgment: nil
    })
  end

  defp fold(task, %{type: "TaskSOPAcknowledgedV1", payload: p, signers: [signer]} = env) do
    put_in(task, [:readiness, :acknowledgment], %{
      event_id: env.event_id,
      custody_receipt_id: p["custody_receipt_id"],
      principal_id: p["principal_id"],
      key_id: signer.key_id,
      pubkey: signer.pubkey
    })
  end

  defp fold(task, %{type: "TaskQueuedV1"}), do: %{task | state: "queued"}

  defp fold(task, %{type: "TaskReadyV1"} = env),
    do:
      task
      |> Map.put(:state, "ready")
      |> Map.put(:ready_receipts, env.payload["custody_receipts"])

  defp fold(task, %{type: "TaskStartedV1", payload: p}),
    do:
      %{
        task
        | state: "in_progress",
          dod: %{task.dod | submission: nil, review: nil}
      }
      |> Map.put(:started_by, p["principal_id"])

  defp fold(task, %{type: "TaskCompletedV1"}), do: %{task | state: "completed"}

  defp fold(task, %{type: type, payload: p} = env) when type in @cancels,
    do:
      task
      |> Map.put(:state, "cancelled")
      |> Map.put(:cancellation, %{
        event_id: env.event_id,
        principal_id: p["principal_id"],
        reason: p["reason"]
      })

  defp fold(task, %{type: "TaskReopenedV1"}),
    do:
      %{
        task
        | state: "queued",
          dod: %{task.dod | submission: nil, review: nil}
      }
      |> Map.put(:started_by, nil)
end
