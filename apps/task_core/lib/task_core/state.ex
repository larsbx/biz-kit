defmodule TaskCore.State do
  @moduledoc """
  Task, grant and suggestion state: a pure fold of accepted events, with no
  storage, side effects or snapshot input. A host's admission check uses
  the same fold as its replay, so what was admitted is what replays.

  The state carries its host (`TaskCore.Host`): the fold references a
  Definition of Done by the host's canonical hash, and admission asks the
  host whether artifact bytes are in its store.
  """

  @typedoc "Where a task lives: `{chapter, tenant, project}`."
  @type scope :: {String.t(), String.t(), String.t()}

  @doc "The state before any event, for `host`."
  @spec init(module()) :: map()
  def init(host),
    do:
      Map.merge(
        %{
          host: host,
          grants: %{},
          tasks: %{},
          proposals: %{},
          dod_grants: %{},
          dod_commands: %{},
          custody_receipts: %{}
        },
        TaskCore.Timing.init()
      )
      |> Map.merge(TaskCore.Hierarchy.init())
      |> Map.merge(TaskCore.AgentRuns.init())

  @doc """
  A task entering the inbox at version 1. Baselines and operator creation share
  one shape; baselined tasks start with no timing (`timing_version` 0).
  """
  def new_task(%{} = env, attrs) do
    Map.merge(
      %{
        state: "inbox",
        dod: nil,
        version: 1,
        title: nil,
        description: nil,
        definition_of_done: nil,
        definition_ref: nil,
        legacy_row_id: nil,
        source_digest: nil,
        baseline_event_id: nil,
        timing: %{"schedule" => nil, "due_ms" => nil},
        timing_version: 0,
        timing_delegation_id: nil,
        todos: %{},
        last_event_id: env.event_id
      },
      attrs
    )
  end

  @doc "Fold one accepted event."
  def handle_event(%{type: "TaskOperatorGrantedV1", payload: p} = env, state) do
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

    put_in(state, [:grants, Access.key(env.event_id)], grant)
  end

  def handle_event(%{type: "TaskOperatorRevokedV1", payload: p}, state),
    do: put_in(state, [:grants, p["authorization_event_id"], :active], false)

  # A device of the holder's: an operator or a reviewer grant.
  def handle_event(%{type: type, payload: %{"revoked_grant_event_id" => id}}, state)
      when type in ~w(TaskDeviceRevokedV1 TaskReviewerDeviceRevokedV1) do
    kind = if Map.has_key?(state.grants, id), do: :grants, else: :dod_grants
    put_in(state, [kind, id, :active], false)
  end

  def handle_event(%{type: "TaskPrincipalOffboardedV1", payload: p} = env, state) do
    state
    |> held_by(p["principal_id"], scope(env))
    |> Enum.reduce(state, fn {kind, id}, acc -> put_in(acc, [kind, id, :active], false) end)
  end

  def handle_event(%{type: "TaskBaselineRecordedV1", payload: p} = env, state) do
    task =
      new_task(env, %{
        title: p["title"],
        definition_of_done: p["definition_of_done"],
        definition_ref: p["definition_ref"],
        legacy_row_id: p["legacy_row_id"],
        source_digest: p["source_digest"],
        baseline_event_id: env.event_id
      })

    put_in(state, [:tasks, Access.key(task_key(env))], task)
  end

  def handle_event(%{type: "TaskProposedV1"} = env, state) do
    state
    |> update_in([:tasks, task_key(env)], fn task ->
      %{task | state: "proposed", version: task.version + 1, last_event_id: env.event_id}
    end)
    |> put_in([:proposals, Access.key(env.event_id)], env)
  end

  def handle_event(env, state) do
    state = TaskCore.Readiness.handle_event(env, state)
    state = TaskCore.DoD.handle_event(env, state)
    state = TaskCore.Hierarchy.handle_event(env, state)
    state = TaskCore.Todos.handle_event(env, state)
    state = TaskCore.Timing.handle_event(env, state)
    TaskCore.AgentRuns.handle_event(env, state)
  end

  @authority [:grants, :suggester_grants, :dod_grants, :delegations]

  @doc """
  Everything `principal` actively holds in the project, as `{kind, event_id}`:
  operator (device), suggester and reviewer grants, and delegations made to
  or by them. Offboarding ends exactly these.
  """
  def held_by(state, principal, scope) do
    for {kind, id, a} <- authorities(state),
        a.active,
        {a.chapter_id, a.tenant_id, a.project_id} == scope,
        principal in holders(a),
        do: {kind, id}
  end

  @doc "Every grant and delegation, active or not, as `{kind, event_id, authority}`."
  def authorities(state),
    do: for(kind <- @authority, {id, a} <- Map.fetch!(state, kind), do: {kind, id, a})

  @doc "The principals an authority is held by: its holder and, for a delegation, its delegator."
  def holders(a), do: Enum.reject([a.principal_id, a[:delegator_principal_id]], &is_nil/1)

  def scope(%{chapter_id: ch, payload: p}), do: {ch, p["tenant_id"], p["project_id"]}

  def task_key(%{chapter_id: ch, payload: p}),
    do: {ch, p["tenant_id"], p["project_id"], p["task_id"]}
end
