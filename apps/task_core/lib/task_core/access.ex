defmodule TaskCore.Access do
  @moduledoc """
  Independent, revision-bound task permissions for any authenticated principal.

  Read and execute are separate governance-signed grants. Neither permits
  business writes, suggestion acceptance, evidence admission or completion.
  These rules apply equally to people, services and agents; runtime policy
  and authentication belong to the host. The host supplies current committed
  replay and an authenticated principal, never a principal asserted by a tool.
  Recheck at disclosure, launch, renewal and candidate admission. A successful
  check is not a reusable bearer token or a guarantee against a later revoke.
  """

  alias TaskCore.{Admission, State}

  @scope %{"tenant_id" => :string, "project_id" => :string, "task_id" => :string}
  @actions ~w(read execute)
  @request_fields ~w(chapter_id tenant_id project_id task_id principal_id grant_event_id action task_version source_event_id)a

  def init, do: %{task_access_grants: %{}}

  def event_types do
    %{
      "TaskAccessGrantedV1" =>
        spec(%{
          "principal_id" => :string,
          "action" => :string,
          "expected_task_version" => :int,
          "source_event_id" => :string
        }),
      "TaskAccessRevokedV1" => spec(%{"grant_event_id" => :string})
    }
  end

  defp spec(fields) do
    %{
      required_roles: ["governance"],
      disclosure_class: :edges,
      stream: {:payload_fields, "task_access", ~w(tenant_id project_id task_id)},
      payload: %{required: Map.merge(@scope, fields), optional: %{}}
    }
  end

  def check(%{type: "TaskAccessGrantedV1", payload: p} = env, state, keys) do
    with :ok <- Admission.governance_declared(env, keys),
         true <- valid_grant?(p) or {:error, :invalid_task_access_grant},
         false <- Map.has_key?(state.task_access_grants, env.event_id),
         {:ok, task} <- fetch(state.tasks, State.task_key(env), :unknown_task) do
      current_revision(task, p["expected_task_version"], p["source_event_id"])
    else
      true -> {:error, :task_access_grant_already_recorded}
      {:error, _} = error -> error
    end
  end

  def check(%{type: "TaskAccessRevokedV1", payload: p} = env, state, keys) do
    with :ok <- Admission.governance_declared(env, keys),
         {:ok, grant} <- fetch(state.task_access_grants, p["grant_event_id"], :unknown_task_access_grant),
         true <- grant.task_key == State.task_key(env) or {:error, :task_access_scope_mismatch} do
      if grant.active, do: :ok, else: {:error, :task_access_revoked}
    end
  end

  def check(_env, _state, _keys), do: {:error, :unknown_task_access_event}

  def handle_event(%{type: "TaskAccessGrantedV1", payload: p} = env, state) do
    grant = %{
      chapter_id: env.chapter_id,
      tenant_id: p["tenant_id"],
      project_id: p["project_id"],
      task_key: State.task_key(env),
      principal_id: p["principal_id"],
      action: p["action"],
      task_version: p["expected_task_version"],
      source_event_id: p["source_event_id"],
      active: true
    }

    put_in(state, [:task_access_grants, Elixir.Access.key(env.event_id)], grant)
  end

  def handle_event(%{type: "TaskAccessRevokedV1", payload: p}, state),
    do: put_in(state, [:task_access_grants, p["grant_event_id"], :active], false)

  def handle_event(_env, state), do: state

  @doc "Check one permission against fresh trusted replay. No task body is returned."
  def authorize(%{task_access_grants: grants, tasks: tasks}, request)
      when is_map(grants) and is_map(tasks) and is_map(request) do
    with true <- valid_request?(request) or {:error, :invalid_task_access_request},
         {:ok, grant} <- fetch(grants, request.grant_event_id, :unknown_task_access_grant),
         :ok <- matching_grant(grant, request),
         {:ok, task} <- fetch(tasks, task_key(request), :unknown_task) do
      current_revision(task, request.task_version, request.source_event_id)
    end
  end

  def authorize(_state, _request), do: {:error, :invalid_task_access_request}

  defp matching_grant(%{active: false}, _request), do: {:error, :task_access_revoked}

  defp matching_grant(grant, r) do
    cond do
      grant.task_key != task_key(r) -> {:error, :task_access_scope_mismatch}
      grant.principal_id != r.principal_id -> {:error, :task_access_principal_mismatch}
      grant.action != r.action -> {:error, :task_access_action_mismatch}
      true -> current_revision(grant, r.task_version, r.source_event_id)
    end
  end

  defp current_revision(%{version: version, last_event_id: source}, version, source), do: :ok

  defp current_revision(%{task_version: version, source_event_id: source}, version, source),
    do: :ok

  defp current_revision(_task, _version, _source), do: {:error, :stale_task_access_revision}

  defp valid_grant?(p) do
    Enum.all?(~w(principal_id source_event_id), &Admission.segment?(p[&1])) and
      p["action"] in @actions and positive_version?(p["expected_task_version"])
  end

  defp valid_request?(r) do
    Enum.sort(Map.keys(r)) == Enum.sort(@request_fields) and
      Enum.all?(@request_fields -- [:action, :task_version], &Admission.segment?(r[&1])) and
      r.action in @actions and positive_version?(r.task_version)
  end

  defp positive_version?(v), do: is_integer(v) and v in 1..2_147_483_647
  defp task_key(r), do: {r.chapter_id, r.tenant_id, r.project_id, r.task_id}

  defp fetch(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, reason}
    end
  end
end
