defmodule TaskCore.Delegation do
  @moduledoc """
  Delegated task changes (docs/architecture/2026-10-18-task-delegation.md;
  state machine in spec/task_suggestions.qnt).

  An operator delegates a class of timing changes, or task creation, from their
  own operator grant to an agent key. The agent signs the ordinary
  `TaskCreatedV1` / `TaskTimingRevisedV1` commands citing the delegation; the
  gate admits them only while the delegation is live and within its limits.
  A delegation is bound to one operator-grant event: revoking that grant ends
  it, and a later re-grant does not revive it. Lifecycle commands look up
  operator grants only, so they can never be delegated.
  """

  alias TaskCore.Timing

  @kinds ~w(timing create)
  @states ~w(inbox proposed queued ready)
  @default_states ~w(inbox proposed)
  @kind_of %{"TaskCreatedV1" => "create", "TaskTimingRevisedV1" => "timing"}
  @max_block_ms 31 * 86_400_000
  @max_budget 10_000
  @segment ~r/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\z/

  def event_types(scope, actor) do
    %{
      "TaskDelegationGrantedV1" =>
        Timing.spec(
          "operator",
          "task_delegations",
          scope,
          Map.merge(actor, %{
            "delegate_principal_id" => :string,
            "key_id" => :string,
            "pubkey" => :pubkey,
            "kinds" => :any,
            "window" => :any,
            "max_block_ms" => :int,
            "budget" => :int
          }),
          %{"task_ids" => :any, "states" => :any}
        ),
      "TaskDelegationRevokedV1" =>
        Timing.spec(
          "operator",
          "task_delegations",
          scope,
          Map.put(actor, "delegation_event_id", :string)
        )
    }
  end

  # -- delegation events -----------------------------------------------------------

  @doc "Limits of a new delegation: `:ok` or `{:error, {:invalid_delegation, field}}`."
  def validate(p) do
    [
      kinds: subset?(p["kinds"], @kinds),
      window: window?(p["window"]),
      max_block_ms: p["max_block_ms"] in 1..@max_block_ms,
      budget: p["budget"] in 1..@max_budget,
      task_ids: is_nil(p["task_ids"]) or subset?(p["task_ids"], &segment?/1),
      states: is_nil(p["states"]) or subset?(p["states"], @states)
    ]
    |> Enum.find_value(:ok, fn {field, ok} ->
      if !ok, do: {:error, {:invalid_delegation, field}}
    end)
  end

  # A nonempty list without duplicates whose members all pass `allowed`.
  defp subset?(list, allowed) when is_list(list) and list != [] do
    member? = if is_function(allowed), do: allowed, else: &(&1 in allowed)
    Enum.uniq(list) == list and Enum.all?(list, member?)
  end

  defp subset?(_list, _allowed), do: false

  defp segment?(value), do: is_binary(value) and Regex.match?(@segment, value)

  defp window?(%{"not_before_ms" => from, "not_after_ms" => to} = w)
       when map_size(w) == 2 and is_integer(from) and is_integer(to),
       do: from >= 0 and from < to

  defp window?(_window), do: false

  def check_revocation(%{payload: p} = env, state) do
    with {:ok, d} <- fetch(state.delegations, p["delegation_event_id"], :unknown_delegation),
         :ok <- Timing.same_scope(env, d, :unknown_delegation) do
      cond do
        d.delegator_principal_id != p["principal_id"] -> {:error, :delegation_not_own}
        not d.active -> {:error, :delegation_already_revoked}
        true -> :ok
      end
    end
  end

  # -- delegated commands -----------------------------------------------------------

  @doc """
  Liveness and identity of an agent acting under delegation `d`: steps 1 and 2
  of the admission rules. Also authorises recording reasoning artifacts.
  """
  def live(%{payload: p, signers: [signer]} = env, d, state) do
    with :ok <- Timing.same_scope(env, d, :task_grant_scope_mismatch) do
      cond do
        not d.active -> {:error, :delegation_revoked}
        not state.grants[d.operator_grant_id].active -> {:error, :delegator_grant_revoked}
        d.used >= d.budget -> {:error, :delegation_budget_exhausted}
        p["principal_id"] != d.principal_id -> {:error, :task_principal_mismatch}
        {signer.key_id, signer.pubkey} != {d.key_id, d.pubkey} -> {:error, :delegate_key_mismatch}
        true -> :ok
      end
    end
  end

  @doc "Steps 1 to 3: a live, correctly signed command of a delegated kind and target."
  def admit(%{type: type, payload: p} = env, d, state) do
    with :ok <- live(env, d, state) do
      cond do
        p["lifecycle_version"] != 1 -> {:error, :unsupported_task_lifecycle}
        @kind_of[type] not in d.kinds -> {:error, :delegation_kind_not_allowed}
        d.task_ids && p["task_id"] not in d.task_ids -> {:error, :delegation_task_not_allowed}
        Map.has_key?(p, "suggestion_event_id") -> {:error, :delegated_cannot_resolve}
        true -> :ok
      end
    end
  end

  @doc """
  Step 4: the delegation's limits on a validated timing. `task` is the current
  task for a revision, `nil` for a creation.
  """
  def limits(d, %{"schedule" => slot, "due_ms" => due}, nil) do
    cond do
      due != nil -> {:error, :delegation_cannot_change_due}
      slot == nil -> :ok
      true -> slot_limits(d, slot)
    end
  end

  def limits(d, %{"schedule" => slot, "due_ms" => due}, task) do
    current = task.timing["schedule"]

    cond do
      task.state not in (d.states || @default_states) -> {:error, :delegation_state_not_allowed}
      due != task.timing["due_ms"] -> {:error, :delegation_cannot_change_due}
      not (current == nil or in_window?(d, current)) -> {:error, :delegation_outside_window}
      true -> slot_limits(d, slot)
    end
  end

  defp slot_limits(d, slot) do
    cond do
      not in_window?(d, slot) -> {:error, :delegation_outside_window}
      slot["end_ms"] - slot["start_ms"] > d.max_block_ms -> {:error, :delegation_block_too_long}
      true -> :ok
    end
  end

  # Unscheduled and all-day schedules are never inside a window.
  defp in_window?(%{window: w}, %{"kind" => "timed", "start_ms" => from, "end_ms" => to}),
    do: from >= w["not_before_ms"] and to <= w["not_after_ms"]

  defp in_window?(_d, _schedule), do: false

  defp fetch(map, key, error) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, error}
    end
  end

  # -- projection -------------------------------------------------------------------

  def init, do: %{delegations: %{}}

  def handle_event(%{type: "TaskDelegationGrantedV1", payload: p} = env, state) do
    delegation = %{
      chapter_id: env.chapter_id,
      tenant_id: p["tenant_id"],
      project_id: p["project_id"],
      delegator_principal_id: p["principal_id"],
      operator_grant_id: p["authorization_event_id"],
      principal_id: p["delegate_principal_id"],
      key_id: p["key_id"],
      pubkey: elem(p["pubkey"], 1),
      kinds: p["kinds"],
      task_ids: p["task_ids"],
      states: p["states"],
      window: p["window"],
      max_block_ms: p["max_block_ms"],
      budget: p["budget"],
      used: 0,
      active: true
    }

    put_in(state, [:delegations, Access.key(env.event_id)], delegation)
  end

  def handle_event(%{type: "TaskDelegationRevokedV1", payload: p}, state),
    do: put_in(state, [:delegations, p["delegation_event_id"], :active], false)

  @doc "Charge one change to the delegation behind `env`, if any; returns its ID or nil."
  def charge(state, %{payload: %{"authorization_event_id" => id}}) do
    if Map.has_key?(state.delegations, id),
      do: {update_in(state, [:delegations, id, :used], &(&1 + 1)), id},
      else: {state, nil}
  end
end
