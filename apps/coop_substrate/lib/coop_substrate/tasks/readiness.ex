defmodule CoopSubstrate.Tasks.Readiness do
  @moduledoc """
  Isolated proposed -> queued -> ready path. Governance commits exact input
  digests, predecessor IDs and a required SOP digest, and queuing requires the
  task's Definition of Done. Operators acknowledge the
  SOP and request transitions; reviews confer no lifecycle authority. Replay
  folds accepted facts without filesystem reads or execution effects.
  """
  alias CoopSubstrate.Projections.Tasks, as: Projection
  alias CoopSubstrate.Harness.Artifacts
  alias CoopSubstrate.Protocol.Envelope

  @commands ~w(TaskReadinessDefinedV1 TaskSOPAcknowledgedV1 TaskQueuedV1 TaskReadyV1)
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
      "TaskReadyV1" => spec("operator", Map.put(@actor, "custody_receipts", :any))
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

  def check(%Envelope{payload: p} = env, state, keys) do
    with :ok <- authority(env, state, keys),
         {:ok, task} <- current_task(env, state) do
      check_command(env, p, task, state)
    end
  end

  defp authority(%Envelope{type: "TaskReadinessDefinedV1", signers: [signer]} = env, _, keys) do
    if get_in(keys, [{env.chapter_id, "governance"}, signer.key_id]) == signer.pubkey,
      do: :ok,
      else: {:error, :task_governance_not_declared}
  end

  defp authority(%Envelope{payload: p} = env, state, _) do
    with {:ok, grant} <- fetch(state.grants, p["authorization_event_id"], :unknown_task_grant),
         :ok <- CoopSubstrate.Tasks.authorized(env, grant) do
      if p["lifecycle_version"] == 1, do: :ok, else: {:error, :unsupported_task_lifecycle}
    end
  end

  defp current_task(env, state) do
    with {:ok, task} <- fetch(state.tasks, Projection.task_key(env), :unknown_task) do
      if env.payload["expected_version"] == task.version,
        do: {:ok, task},
        else: {:error, {:stale_task_version, env.payload["expected_version"], task.version}}
    end
  end

  defp check_command(%Envelope{type: "TaskReadinessDefinedV1"} = env, p, task, state) do
    with :ok <- transition(task, ["proposed", "queued"], "define_readiness"),
         :ok <- requirements(p["artifact_requirements"]),
         :ok <- predecessors(env, p["predecessor_ids"], state),
         do: :ok
  end

  defp check_command(%Envelope{type: "TaskSOPAcknowledgedV1"} = env, p, task, state) do
    with :ok <- transition(task, ["proposed", "queued"], "acknowledge_sop"),
         {:ok, definition} <- definition(task),
         {:ok, _} <-
           receipt(env, p["custody_receipt_id"], definition.sop_digest, state, 8 * 1024 * 1024),
         do: :ok
  end

  defp check_command(%Envelope{type: "TaskQueuedV1"} = env, _, task, state) do
    with :ok <- transition(task, ["proposed"], "queued"),
         :ok <- dod_defined(task),
         {:ok, _} <- definition(task),
         :ok <- acknowledgment(env, task, state),
         do: :ok
  end

  defp check_command(%Envelope{type: "TaskReadyV1"} = env, p, task, state) do
    with :ok <- transition(task, ["queued"], "ready"),
         {:ok, definition} <- definition(task),
         :ok <- acknowledgment(env, task, state),
         :ok <- completed_predecessors(env, definition.predecessor_ids, state),
         :ok <-
           input_receipts(env, definition.artifact_requirements, p["custody_receipts"], state),
         do: :ok
  end

  defp transition(task, allowed, to) do
    if task.state in allowed,
      do: :ok,
      else: {:error, {:invalid_task_transition, task.state, to}}
  end

  # A DoD can only be defined while a task is proposed (Tasks.DoD), so queuing
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

  defp predecessor_key(env, id), do: put_elem(Projection.task_key(env), 3, id)

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
         do: Artifacts.verify(elem(digest, 1), budget)
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

  def handle_event(%Envelope{type: type} = env, state) when type in @commands do
    state
    |> update_in([:tasks, Projection.task_key(env)], fn task ->
      task
      |> fold(env)
      |> Map.put(:version, task.version + 1)
      |> Map.put(:last_event_id, env.event_id)
    end)
    |> put_in([:dod_commands, Access.key(env.event_id)], env)
  end

  def handle_event(_, state), do: state

  defp fold(task, %Envelope{type: "TaskReadinessDefinedV1", payload: p} = env) do
    Map.put(task, :readiness, %{
      event_id: env.event_id,
      artifact_requirements: p["artifact_requirements"],
      predecessor_ids: p["predecessor_ids"],
      sop_digest: p["sop_digest"],
      acknowledgment: nil
    })
  end

  defp fold(task, %Envelope{type: "TaskSOPAcknowledgedV1", payload: p, signers: [signer]} = env) do
    put_in(task, [:readiness, :acknowledgment], %{
      event_id: env.event_id,
      custody_receipt_id: p["custody_receipt_id"],
      principal_id: p["principal_id"],
      pubkey: signer.pubkey
    })
  end

  defp fold(task, %Envelope{type: "TaskQueuedV1"}), do: %{task | state: "queued"}

  defp fold(task, %Envelope{type: "TaskReadyV1"} = env),
    do:
      task
      |> Map.put(:state, "ready")
      |> Map.put(:ready_receipts, env.payload["custody_receipts"])
end
