defmodule TaskCore.Timing do
  @moduledoc """
  Task timing and agent suggestions
  (docs/architecture/2026-10-18-task-timing-and-suggestions.md; state machine
  in spec/task_suggestions.qnt).

  Operators create tasks and revise their timing facet, which has its own
  version counter so calendar edits never invalidate lifecycle commands. Agents
  may issue the same two commands under a live delegation, within its limits
  (`TaskCore.Delegation`).
  Suggesters (agents) hold a separate grant whose events only fill a review
  queue: an operator command citing a suggestion resolves it, and task state is
  a function of operator events alone. Agent documents fold into
  `suggestion_artifacts`, never `custody_receipts`, so no operator command can
  cite one as evidence, SOP acknowledgement or ready input.
  """

  alias TaskCore.State
  alias TaskCore.Admission
  alias TaskCore.Delegation

  @scope %{"tenant_id" => :string, "project_id" => :string}
  @subject Map.put(@scope, "task_id", :string)
  @actor %{
    "principal_id" => :string,
    "authorization_event_id" => :string,
    "lifecycle_version" => :int
  }
  @suggester %{"principal_id" => :string, "authorization_event_id" => :string}
  @grant %{"principal_id" => :string, "key_id" => :string, "pubkey" => :pubkey}
  # Accepted on delegated commands only.
  @reasoning %{"rationale" => :string, "rationale_receipt_id" => :string}

  @day_ms 86_400_000
  @max_timed_ms 31 * @day_ms
  @max_all_day_days 366
  @max_rationale 1000
  @max_artifact_bytes 1024 * 1024
  @tz ~r/\A[A-Za-z_]+(\/[A-Za-z0-9_+-]+){0,2}\z/

  # Fields a command takes from a Δ; Accepted iff they are equal.
  @body %{"create" => ~w(title timing description), "timing" => ~w(timing)}
  @resolves %{"TaskCreatedV1" => "create", "TaskTimingRevisedV1" => "timing"}

  def event_types do
    %{
      "TaskSuggesterGrantedV1" => spec("governance", "task_suggesters", @scope, @grant),
      "TaskSuggesterRevokedV1" =>
        spec("governance", "task_suggesters", @scope, %{"authorization_event_id" => :string}),
      "TaskCreatedV1" =>
        spec(
          "operator",
          "tasks",
          @subject,
          Map.merge(@actor, %{"title" => :string, "timing" => :any}),
          Map.merge(@reasoning, %{
            "description" => :string,
            "suggestion_event_id" => :string
          })
        ),
      "TaskTimingRevisedV1" =>
        spec(
          "operator",
          "tasks",
          @subject,
          Map.merge(@actor, %{"expected_timing_version" => :int, "timing" => :any}),
          Map.put(@reasoning, "suggestion_event_id", :string)
        ),
      "TaskSuggestionDeclinedV1" =>
        spec(
          "operator",
          "task_suggestions",
          @scope,
          Map.merge(@actor, %{"suggestion_event_id" => :string, "reason" => :string}),
          %{"reason_receipt_id" => :string}
        ),
      "TaskChangeSuggestedV1" =>
        spec(
          "suggester",
          "task_suggestions",
          @scope,
          Map.merge(@suggester, %{"task_id" => :string, "change" => :any, "rationale" => :string}),
          %{"base_timing_version" => :int, "rationale_receipt_id" => :string}
        ),
      "TaskSuggestionWithdrawnV1" =>
        spec(
          "suggester",
          "task_suggestions",
          @scope,
          Map.put(@suggester, "suggestion_event_id", :string),
          %{"reason" => :string, "reason_receipt_id" => :string}
        ),
      "TaskSuggestionArtifactRecordedV1" =>
        spec(
          "suggester",
          "task_suggestions",
          @scope,
          Map.put(@suggester, "artifact_digest", :hash)
        )
    }
    |> Map.merge(Delegation.event_types(@scope, @actor))
  end

  @doc false
  def spec(role, prefix, scope, fields, optional \\ %{}) do
    %{
      required_roles: [role],
      disclosure_class: :edges,
      stream: {:payload_fields, prefix, stream_fields(scope)},
      payload: %{required: Map.merge(scope, fields), optional: optional}
    }
  end

  # Stream segments in canonical order: tenant, project[, task].
  defp stream_fields(%{"task_id" => _}), do: ~w(tenant_id project_id task_id)
  defp stream_fields(_scope), do: ~w(tenant_id project_id)

  # -- admission ----------------------------------------------------------------

  def check(%{type: "TaskSuggesterGrantedV1", payload: p} = env, state, keys) do
    with :ok <- Admission.governance_declared(env, keys),
         :ok <- Admission.nonempty_fields(p, ~w(principal_id key_id)) do
      if Map.has_key?(state.suggester_grants, env.event_id),
        do: {:error, :grant_already_recorded},
        else: :ok
    end
  end

  def check(%{type: "TaskSuggesterRevokedV1", payload: p} = env, state, keys) do
    with :ok <- Admission.governance_declared(env, keys),
         {:ok, grant} <-
           fetch(state.suggester_grants, p["authorization_event_id"], :unknown_suggester_grant),
         :ok <- same_scope(env, grant, :task_grant_scope_mismatch) do
      if grant.active, do: :ok, else: {:error, :suggester_already_revoked}
    end
  end

  def check(%{type: "TaskCreatedV1", payload: p} = env, state, _keys) do
    with {:ok, via} <- authority(env, state),
         :ok <- Admission.nonempty_fields(p, ~w(title)),
         :ok <- timing(p["timing"]),
         :ok <- delegated_limits(via, p["timing"], nil),
         :ok <- absent(state, env),
         do: cited(env, state)
  end

  def check(%{type: "TaskTimingRevisedV1", payload: p} = env, state, _keys) do
    with {:ok, via} <- authority(env, state),
         {:ok, task} <- fetch(state.tasks, State.task_key(env), :unknown_task),
         :ok <- open(task),
         :ok <- expected(p["expected_timing_version"], task.timing_version),
         :ok <- timing(p["timing"]),
         :ok <- delegated_limits(via, p["timing"], task),
         do: cited(env, state)
  end

  def check(%{type: "TaskDelegationGrantedV1", payload: p} = env, state, _keys) do
    with :ok <- operator(env, state),
         :ok <- Admission.nonempty_fields(p, ~w(delegate_principal_id key_id)),
         :ok <- unrecorded(state.delegations, env),
         do: Delegation.validate(p)
  end

  def check(%{type: "TaskDelegationRevokedV1"} = env, state, _keys) do
    with :ok <- operator(env, state), do: Delegation.check_revocation(env, state)
  end

  def check(%{type: "TaskSuggestionDeclinedV1", payload: p} = env, state, _keys) do
    with :ok <- operator(env, state),
         {:ok, _suggestion} <- pending(env, state),
         do: operator_receipt(env, state, p["reason_receipt_id"])
  end

  def check(%{type: "TaskChangeSuggestedV1", payload: p} = env, state, _keys) do
    with :ok <- suggester(env, state),
         :ok <- unrecorded(state.suggestions, env),
         :ok <- rationale(p["rationale"]),
         :ok <- change(p["change"]),
         :ok <- target(p["change"]["kind"], env, state),
         do: own_artifact(env, state, p["rationale_receipt_id"])
  end

  def check(%{type: "TaskSuggestionWithdrawnV1", payload: p} = env, state, _keys) do
    with :ok <- suggester(env, state),
         {:ok, suggestion} <- pending(env, state),
         true <- suggestion.principal_id == p["principal_id"] or {:error, :suggestion_not_own},
         do: own_artifact(env, state, p["reason_receipt_id"])
  end

  def check(%{type: "TaskSuggestionArtifactRecordedV1", payload: p} = env, state, _keys) do
    with :ok <- agent(env, state),
         true <-
           not (Map.has_key?(state.suggestion_artifacts, env.event_id) or
                  Map.has_key?(state.custody_receipts, env.event_id)) or
             {:error, :custody_id_conflict},
         {:ok, _bytes} <-
           state.host.verify_artifact(elem(p["artifact_digest"], 1), @max_artifact_bytes),
         do: :ok
  end

  # Who may issue a create or timing command: an operator, or an agent under a
  # live delegation. Reasoning fields belong to delegated commands only.
  defp authority(%{payload: p} = env, state) do
    case state.delegations[p["authorization_event_id"]] do
      nil ->
        with :ok <- operator(env, state) do
          if Map.has_key?(p, "rationale") or Map.has_key?(p, "rationale_receipt_id"),
            do: {:error, :rationale_requires_delegation},
            else: {:ok, :operator}
        end

      delegation ->
        with :ok <- Delegation.admit(env, delegation, state),
             :ok <- if(p["rationale"], do: rationale(p["rationale"]), else: :ok),
             :ok <- own_artifact(env, state, p["rationale_receipt_id"]),
             do: {:ok, delegation}
    end
  end

  defp delegated_limits(:operator, _timing, _task), do: :ok
  defp delegated_limits(delegation, timing, task), do: Delegation.limits(delegation, timing, task)

  # Agents record reasoning under a suggester grant or a live delegation.
  defp agent(%{payload: p} = env, state) do
    case state.delegations[p["authorization_event_id"]] do
      nil -> suggester(env, state)
      delegation -> Delegation.live(env, delegation, state)
    end
  end

  defp operator(%{payload: p} = env, state) do
    with {:ok, grant} <- fetch(state.grants, p["authorization_event_id"], :unknown_task_grant),
         :ok <- Admission.authorized(env, grant) do
      if p["lifecycle_version"] == 1, do: :ok, else: {:error, :unsupported_task_lifecycle}
    end
  end

  defp suggester(%{payload: p, signers: [signer]} = env, state) do
    with {:ok, grant} <-
           fetch(state.suggester_grants, p["authorization_event_id"], :unknown_suggester_grant),
         :ok <- same_scope(env, grant, :task_grant_scope_mismatch) do
      cond do
        not grant.active ->
          {:error, :task_suggester_revoked}

        p["principal_id"] != grant.principal_id ->
          {:error, :task_principal_mismatch}

        {signer.key_id, signer.pubkey} != {grant.key_id, grant.pubkey} ->
          {:error, :task_suggester_key_mismatch}

        true ->
          :ok
      end
    end
  end

  defp absent(state, env) do
    if Map.has_key?(state.tasks, State.task_key(env)),
      do: {:error, :task_already_recorded},
      else: :ok
  end

  defp expected(expected, current) when expected == current, do: :ok
  defp expected(expected, current), do: {:error, {:stale_timing_version, expected, current}}

  # An operator command may cite one pending suggestion of its own kind and task.
  defp cited(%{type: type, payload: %{"suggestion_event_id" => _}} = env, state) do
    with {:ok, suggestion} <- pending(env, state) do
      if suggestion.kind == @resolves[type] and suggestion.task_id == env.payload["task_id"],
        do: :ok,
        else: {:error, :suggestion_mismatch}
    end
  end

  defp cited(_env, _state), do: :ok

  defp pending(%{payload: %{"suggestion_event_id" => id}} = env, state) do
    with {:ok, suggestion} <- fetch(state.suggestions, id, :unknown_suggestion),
         :ok <- same_scope(env, suggestion, :suggestion_mismatch) do
      if suggestion.status == :pending,
        do: {:ok, suggestion},
        else: {:error, :suggestion_not_pending}
    end
  end

  defp target("create", env, state), do: absent(state, env)

  defp target("timing", %{payload: p} = env, state) do
    with true <- is_integer(p["base_timing_version"]) or {:error, :suggestion_base_required},
         {:ok, task} <- fetch(state.tasks, State.task_key(env), :unknown_task),
         :ok <- open(task) do
      if p["base_timing_version"] <= task.timing_version,
        do: :ok,
        else: {:error, :suggestion_base_ahead}
    end
  end

  # A cancelled task is not rescheduled (docs/architecture/2026-10-19-cancel-reopen.md).
  defp open(%{state: "cancelled"}), do: {:error, :task_cancelled}
  defp open(_task), do: :ok

  defp rationale(text) do
    if String.trim(text) != "" and String.length(text) <= @max_rationale,
      do: :ok,
      else: {:error, :invalid_rationale}
  end

  # An agent cites only documents it recorded itself, in the same scope.
  defp own_artifact(_env, _state, nil), do: :ok

  defp own_artifact(%{payload: p} = env, state, id) do
    with {:ok, receipt} <- fetch(state.suggestion_artifacts, id, :unknown_suggestion_artifact),
         :ok <- same_scope(env, receipt, :suggestion_artifact_not_own) do
      if receipt.principal_id == p["principal_id"],
        do: :ok,
        else: {:error, :suggestion_artifact_not_own}
    end
  end

  # An operator's reason cites operator custody only.
  defp operator_receipt(_env, _state, nil), do: :ok

  defp operator_receipt(env, state, id) do
    with {:ok, receipt} <- fetch(state.custody_receipts, id, :unknown_custody_receipt),
         do: same_scope(env, receipt, :custody_scope_mismatch)
  end

  defp unrecorded(map, env),
    do: if(Map.has_key?(map, env.event_id), do: {:error, :command_already_recorded}, else: :ok)

  @doc false
  def same_scope(%{chapter_id: ch, payload: p}, record, error) do
    if {ch, p["tenant_id"], p["project_id"]} ==
         {record.chapter_id, record.tenant_id, record.project_id},
       do: :ok,
       else: {:error, error}
  end

  defp fetch(map, key, error) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, error}
    end
  end

  # -- value validation -----------------------------------------------------------

  @doc "Validate a timing value: `:ok` or `{:error, {:invalid_task_timing, reason}}`."
  def timing(value) do
    case timing_error(value) do
      nil -> :ok
      reason -> {:error, {:invalid_task_timing, reason}}
    end
  end

  defp timing_error(%{"schedule" => schedule, "due_ms" => due} = t) when map_size(t) == 2 do
    cond do
      not (is_nil(due) or (is_integer(due) and due >= 0)) -> :due
      is_nil(schedule) -> nil
      true -> schedule_error(schedule)
    end
  end

  defp timing_error(_), do: :keys

  defp schedule_error(%{"kind" => "timed"} = s) do
    with :ok <- exact_keys(s, ~w(kind start_ms end_ms tz)) do
      %{"start_ms" => from, "end_ms" => to, "tz" => tz} = s

      cond do
        not (is_integer(from) and is_integer(to) and from >= 0) -> :negative_time
        from >= to -> :schedule_order
        to - from > @max_timed_ms -> :schedule_span
        not (is_binary(tz) and Regex.match?(@tz, tz)) -> :timezone
        true -> nil
      end
    end
  end

  defp schedule_error(%{"kind" => "all_day"} = s) do
    with :ok <- exact_keys(s, ~w(kind start_date end_date)),
         {:ok, from} <- date(s["start_date"]),
         {:ok, to} <- date(s["end_date"]) do
      cond do
        Date.compare(from, to) != :lt -> :date_order
        Date.diff(to, from) > @max_all_day_days -> :schedule_span
        true -> nil
      end
    end
  end

  defp schedule_error(_), do: :schedule_kind

  defp exact_keys(map, keys),
    do: if(Enum.sort(Map.keys(map)) == Enum.sort(keys), do: :ok, else: :keys)

  defp date(value) when is_binary(value) and byte_size(value) == 10 do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> :date_format
    end
  end

  defp date(_), do: :date_format

  defp change(%{"kind" => "timing"} = c) do
    with :ok <- change_keys(c, ~w(kind timing), []), do: timing(c["timing"])
  end

  defp change(%{"kind" => "create"} = c) do
    with :ok <- change_keys(c, ~w(kind title timing), ~w(description)),
         true <-
           (is_binary(c["title"]) and String.trim(c["title"]) != "") or
             {:error, {:invalid_suggestion_change, :title}},
         # Omitted, or a string: TaskCreatedV1 cannot carry a null description,
         # so a null one could never be accepted unchanged.
         true <-
           not Map.has_key?(c, "description") or is_binary(c["description"]) or
             {:error, {:invalid_suggestion_change, :description}},
         do: timing(c["timing"])
  end

  defp change(_), do: {:error, {:invalid_suggestion_change, :kind}}

  defp change_keys(c, required, optional) do
    keys = MapSet.new(Map.keys(c))

    if MapSet.subset?(MapSet.new(required), keys) and
         MapSet.subset?(keys, MapSet.new(required ++ optional)),
       do: :ok,
       else: {:error, {:invalid_suggestion_change, :keys}}
  end

  # -- projection -------------------------------------------------------------------

  def init,
    do:
      Map.merge(Delegation.init(), %{
        suggester_grants: %{},
        suggestions: %{},
        suggestion_artifacts: %{},
        timing_commands: %{}
      })

  def handle_event(%{type: "TaskSuggesterGrantedV1", payload: p} = env, state) do
    grant = %{
      chapter_id: env.chapter_id,
      tenant_id: p["tenant_id"],
      project_id: p["project_id"],
      principal_id: p["principal_id"],
      key_id: p["key_id"],
      pubkey: elem(p["pubkey"], 1),
      active: true
    }

    put_in(state, [:suggester_grants, Access.key(env.event_id)], grant)
  end

  def handle_event(%{type: "TaskSuggesterRevokedV1", payload: p}, state),
    do: put_in(state, [:suggester_grants, p["authorization_event_id"], :active], false)

  def handle_event(%{type: "TaskCreatedV1", payload: p} = env, state) do
    {state, delegation_id} = Delegation.charge(state, env)

    task =
      State.new_task(env, %{
        title: p["title"],
        description: p["description"],
        timing: p["timing"],
        timing_version: 1,
        timing_delegation_id: delegation_id
      })

    state
    |> put_in([:tasks, Access.key(State.task_key(env))], task)
    |> resolve_cited(env)
    |> supersede_creates(env)
    |> command(env)
  end

  def handle_event(%{type: "TaskTimingRevisedV1", payload: p} = env, state) do
    {state, delegation_id} = Delegation.charge(state, env)

    state
    |> update_in([:tasks, State.task_key(env)], fn task ->
      %{
        task
        | timing: p["timing"],
          timing_version: task.timing_version + 1,
          timing_delegation_id: delegation_id,
          last_event_id: env.event_id
      }
    end)
    |> resolve_cited(env)
    |> command(env)
  end

  def handle_event(%{type: type} = env, state)
      when type in ~w(TaskDelegationGrantedV1 TaskDelegationRevokedV1) do
    state |> then(&Delegation.handle_event(env, &1)) |> command(env)
  end

  def handle_event(%{type: "TaskSuggestionDeclinedV1", payload: p} = env, state) do
    state
    |> resolve(p["suggestion_event_id"], env, :declined, p["reason"], p["reason_receipt_id"])
    |> command(env)
  end

  def handle_event(%{type: "TaskChangeSuggestedV1", payload: p} = env, state) do
    suggestion = %{
      chapter_id: env.chapter_id,
      tenant_id: p["tenant_id"],
      project_id: p["project_id"],
      task_id: p["task_id"],
      kind: p["change"]["kind"],
      change: p["change"],
      principal_id: p["principal_id"],
      base_timing_version: p["base_timing_version"],
      rationale: p["rationale"],
      rationale_receipt_id: p["rationale_receipt_id"],
      status: :pending,
      reason: nil,
      reason_receipt_id: nil,
      resolved_by_event_id: nil
    }

    state
    |> put_in([:suggestions, Access.key(env.event_id)], suggestion)
    |> command(env)
  end

  def handle_event(%{type: "TaskSuggestionWithdrawnV1", payload: p} = env, state) do
    state
    |> resolve(p["suggestion_event_id"], env, :withdrawn, p["reason"], p["reason_receipt_id"])
    |> command(env)
  end

  def handle_event(%{type: "TaskSuggestionArtifactRecordedV1", payload: p} = env, state) do
    receipt = %{
      chapter_id: env.chapter_id,
      tenant_id: p["tenant_id"],
      project_id: p["project_id"],
      principal_id: p["principal_id"],
      digest: p["artifact_digest"]
    }

    state
    |> put_in([:suggestion_artifacts, Access.key(env.event_id)], receipt)
    |> command(env)
  end

  # Cancelling a task resolves its pending timing suggestions: nothing can
  # accept them now.
  def handle_event(%{type: type} = env, state) do
    if type in TaskCore.Readiness.cancels(),
      do: supersede(state, env, &(&1 == "timing")),
      else: state
  end

  defp command(state, env), do: put_in(state, [:timing_commands, Access.key(env.event_id)], env)

  # Accepted iff the command's body equals the Δ's. A citation of a suggestion
  # absent from the fold (a replay without suggester events) is ignored: task
  # state never depends on suggestions.
  defp resolve_cited(state, %{payload: %{"suggestion_event_id" => id} = p} = env) do
    case state.suggestions[id] do
      nil ->
        state

      suggestion ->
        fields = @body[suggestion.kind]

        status =
          if Map.take(p, fields) == Map.take(suggestion.change, fields),
            do: :accepted,
            else: :amended

        resolve(state, id, env, status, nil, nil)
    end
  end

  defp resolve_cited(state, _env), do: state

  # Creating a task resolves every other pending create suggestion for it.
  defp supersede_creates(state, env), do: supersede(state, env, &(&1 == "create"))

  defp supersede(state, env, kind?) do
    key = State.task_key(env)

    state.suggestions
    |> Enum.filter(fn {_id, s} ->
      s.status == :pending and kind?.(s.kind) and
        {s.chapter_id, s.tenant_id, s.project_id, s.task_id} == key
    end)
    |> Enum.reduce(state, fn {id, _}, acc -> resolve(acc, id, env, :superseded, nil, nil) end)
  end

  defp resolve(state, id, env, status, reason, receipt) do
    if Map.has_key?(state.suggestions, id) do
      update_in(state, [:suggestions, id], fn s ->
        %{
          s
          | status: status,
            reason: reason,
            reason_receipt_id: receipt,
            resolved_by_event_id: env.event_id
        }
      end)
    else
      state
    end
  end
end
