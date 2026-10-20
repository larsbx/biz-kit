defmodule TaskCore.Admission do
  @moduledoc """
  Which task events exist and whether one may be appended. Pure: a host
  supplies the state (`TaskCore.State`) and the governance keys it holds,
  and serializes admission itself.

  Each event type's spec names the role that signs it, its payload fields,
  and the fields that scope its stream; a host's registry may use or ignore
  the rest. Task events admit one accountable signer.
  """

  alias TaskCore.State

  @scope %{"tenant_id" => :string, "project_id" => :string}
  @subject Map.put(@scope, "task_id", :string)

  # New types are additive: old canonical cores and verification rules stay put.
  def event_types do
    %{
      "TaskOperatorGrantedV1" =>
        spec(
          "governance",
          "task_grants",
          @scope,
          %{"principal_id" => :string, "key_id" => :string, "pubkey" => :pubkey},
          %{"device_label" => :string}
        ),
      "TaskOperatorRevokedV1" =>
        spec("governance", "task_grants", @scope, %{
          "authorization_event_id" => :string
        }),
      # The holder of a device revokes one of their own devices, an operator or
      # reviewer grant in the project (docs/architecture/2026-10-19-device-revocation.md,
      # 2026-10-19-own-devices.md), signed by one of their operator devices or
      # by one of their reviewer devices. An administrator key is revoked only
      # by governance (`RoleKeyRevoked`), so the governance history alone
      # derives the chapter's keys, offline too (`Export`).
      "TaskDeviceRevokedV1" => holder_revocation("operator"),
      "TaskReviewerDeviceRevokedV1" => holder_revocation("reviewer"),
      # Governance ends everything a principal holds in the project at once
      # (docs/architecture/2026-10-19-offboarding.md).
      "TaskPrincipalOffboardedV1" =>
        spec("governance", "task_grants", @scope, %{"principal_id" => :string}),
      "TaskBaselineRecordedV1" =>
        spec("governance", "tasks", @subject, %{
          "legacy_row_id" => :string,
          "source_digest" => :hash,
          "definition_ref" => :hash,
          "title" => :string,
          "definition_of_done" => :string
        }),
      "TaskProposedV1" =>
        spec("operator", "tasks", @subject, %{
          "principal_id" => :string,
          "authorization_event_id" => :string,
          "expected_version" => :int,
          "lifecycle_version" => :int
        })
    }
    |> Map.merge(TaskCore.DoD.event_types())
    |> Map.merge(TaskCore.Readiness.event_types())
    |> Map.merge(TaskCore.Timing.event_types())
    |> Map.merge(TaskCore.Hierarchy.event_types())
  end

  defp holder_revocation(role),
    do:
      spec(role, "task_grants", @scope, %{
        "principal_id" => :string,
        "authorization_event_id" => :string,
        "revoked_grant_event_id" => :string
      })

  @holder_revocations ~w(TaskDeviceRevokedV1 TaskReviewerDeviceRevokedV1)

  @doc "The holder revocations, by an operator or a reviewer device."
  def holder_revocations, do: @holder_revocations

  defp spec(role, prefix, scope, fields, optional \\ %{}) do
    scope_fields =
      if Map.has_key?(scope, "task_id"),
        do: ["tenant_id", "project_id", "task_id"],
        else: ["tenant_id", "project_id"]

    %{
      required_roles: [role],
      disclosure_class: :edges,
      stream: {:payload_fields, prefix, scope_fields},
      payload: %{required: Map.merge(scope, fields), optional: optional}
    }
  end

  @doc """
  Whether `event` may be appended, given `gate`: `orchestration` (the
  `TaskCore.State`) and `role_keys` (`%{{chapter, role} => %{key_id => pubkey}}`,
  the keys governance declared). `:ok` or `{:error, reason}`.
  """
  def check(%{} = env, gate) do
    with :ok <- signer_cardinality(env),
         :ok <- scope_valid(env) do
      cond do
        Map.has_key?(TaskCore.Readiness.event_types(), env.type) ->
          TaskCore.Readiness.check(env, gate.orchestration, gate.role_keys)

        Map.has_key?(TaskCore.DoD.event_types(), env.type) ->
          TaskCore.DoD.check(env, gate.orchestration, gate.role_keys)

        Map.has_key?(TaskCore.Timing.event_types(), env.type) ->
          TaskCore.Timing.check(env, gate.orchestration, gate.role_keys)

        Map.has_key?(TaskCore.Hierarchy.event_types(), env.type) ->
          TaskCore.Hierarchy.check(env, gate.orchestration, gate.role_keys)

        env.type in @holder_revocations ->
          holder_revocation(env, gate)

        true ->
          check_type(env, gate.orchestration, gate.role_keys)
      end
    end
  end

  # These new governance events require an explicit declared key even while
  # older economic event types retain their original bootstrap semantics.
  defp check_type(%{type: "TaskOperatorGrantedV1", payload: p} = env, state, keys) do
    with :ok <- governance_declared(env, keys),
         :ok <- nonempty_fields(p, ~w(principal_id key_id)),
         :ok <- device_label(p["device_label"]) do
      if Map.has_key?(state.grants, env.event_id),
        do: {:error, :grant_already_recorded},
        else: :ok
    end
  end

  defp check_type(%{type: "TaskOperatorRevokedV1", payload: p} = env, state, keys) do
    with :ok <- governance_declared(env, keys),
         {:ok, grant} <- fetch_grant(state, p["authorization_event_id"]),
         :ok <- grant_scope(env, grant) do
      if grant.active, do: :ok, else: {:error, :grant_already_revoked}
    end
  end

  defp check_type(%{type: "TaskPrincipalOffboardedV1", payload: p} = env, state, keys) do
    with :ok <- governance_declared(env, keys),
         :ok <- nonempty_fields(p, ~w(principal_id)) do
      if State.held_by(state, p["principal_id"], State.scope(env)) == [],
        do: {:error, :nothing_to_offboard},
        else: :ok
    end
  end

  defp check_type(%{type: "TaskBaselineRecordedV1", payload: p} = env, state, keys) do
    with :ok <- governance_declared(env, keys),
         :ok <- nonempty_fields(p, ~w(legacy_row_id title definition_of_done)) do
      if Map.has_key?(state.tasks, State.task_key(env)),
        do: {:error, :task_already_recorded},
        else: :ok
    end
  end

  defp check_type(%{type: "TaskProposedV1", payload: p} = env, state, _keys) do
    with {:ok, grant} <- fetch_grant(state, p["authorization_event_id"]),
         :ok <- grant_scope(env, grant),
         :ok <- operator_authorized(env, grant),
         {:ok, task} <- fetch_task(state, State.task_key(env)) do
      cond do
        Map.has_key?(state.proposals, env.event_id) ->
          {:error, :command_already_recorded}

        p["lifecycle_version"] != 1 ->
          {:error, :unsupported_task_lifecycle}

        p["expected_version"] != task.version ->
          {:error, {:stale_task_version, p["expected_version"], task.version}}

        true ->
          TaskCore.Readiness.move(task, env.type)
      end
    end
  end

  # Task events admit one accountable governance or operator key. Other event
  # types retain their existing multi-signature rules and canonical bytes.
  defp device_label(nil), do: :ok

  defp device_label(label),
    do: if(String.length(label) in 1..80, do: :ok, else: {:error, :invalid_device_label})

  defp signer_cardinality(%{signers: [_signer]}), do: :ok
  defp signer_cardinality(_env), do: {:error, :task_signer_cardinality}

  defp scope_valid(env) do
    fields =
      if Map.has_key?(env.payload, "task_id"),
        do: ~w(tenant_id project_id task_id),
        else: ~w(tenant_id project_id)

    values = [env.chapter_id | Enum.map(fields, &env.payload[&1])]
    if Enum.all?(values, &segment?/1), do: :ok, else: {:error, :invalid_task_scope}
  end

  @doc "Whether `value` is a safe scope segment: 1 to 128 bytes, `[A-Za-z0-9][A-Za-z0-9_.-]*`."
  def segment?(value) do
    is_binary(value) and byte_size(value) in 1..128 and
      Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/, value)
  end

  def nonempty_fields(payload, fields) do
    if Enum.all?(fields, &(String.trim(payload[&1]) != "")),
      do: :ok,
      else: {:error, :empty_task_field}
  end

  def governance_declared(%{signers: [signer]} = env, keys) do
    if Map.get(keys[{env.chapter_id, "governance"}] || %{}, signer.key_id) == signer.pubkey,
      do: :ok,
      else: {:error, :task_governance_not_declared}
  end

  defp fetch_grant(state, id) do
    case Map.fetch(state.grants, id) do
      {:ok, grant} -> {:ok, grant}
      :error -> {:error, :unknown_task_grant}
    end
  end

  defp grant_scope(env, grant) do
    if {env.chapter_id, env.payload["tenant_id"], env.payload["project_id"]} ==
         {grant.chapter_id, grant.tenant_id, grant.project_id},
       do: :ok,
       else: {:error, :task_grant_scope_mismatch}
  end

  def authorized(env, grant) do
    with :ok <- grant_scope(env, grant), do: operator_authorized(env, grant)
  end

  defp operator_authorized(%{signers: [signer]} = env, grant) do
    cond do
      not grant.active ->
        {:error, :task_grant_revoked}

      env.payload["principal_id"] != grant.principal_id ->
        {:error, :task_principal_mismatch}

      {signer.key_id, signer.pubkey} != {grant.key_id, grant.pubkey} ->
        {:error, :task_operator_key_mismatch}

      true ->
        :ok
    end
  end

  defp fetch_task(state, key) do
    case Map.fetch(state.tasks, key) do
      {:ok, task} -> {:ok, task}
      :error -> {:error, :unknown_task}
    end
  end

  # Revocation by the holder: from any of their active operator or reviewer
  # devices in the project, of any of their devices there (operator or
  # reviewer grants), itself included.
  defp holder_revocation(%{type: type, payload: p} = env, gate) do
    o = gate.orchestration
    signers = if type == "TaskReviewerDeviceRevokedV1", do: o.dod_grants, else: o.grants

    with {:ok, signer} <- fetch(signers, p["authorization_event_id"], :unknown_task_grant),
         :ok <- authorized(env, signer),
         do: holder_target(env, signer.principal_id, o)
  end

  defp holder_target(%{payload: %{"revoked_grant_event_id" => id}} = env, holder, o) do
    with {:ok, target} <- fetch(Map.merge(o.dod_grants, o.grants), id, :unknown_task_grant),
         :ok <- grant_scope(env, target) do
      cond do
        target.principal_id != holder -> {:error, :not_own_device}
        not target.active -> {:error, :grant_already_revoked}
        true -> :ok
      end
    end
  end

  defp fetch(map, id, error) do
    case Map.fetch(map, id) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, error}
    end
  end
end
