defmodule CoopSubstrate.Tasks do
  @moduledoc """
  Bounded common-ledger task command: inbox -> proposed, lifecycle version 1.

  Governance records a baseline and a project-scoped operator signing key.
  The operator signs the command; the existing Log serializes admission and
  rechecks its grant and task version against committed state. No cooperative
  membership, Ash row, or local certified-event writer licenses this command.

  Baselines attest source state, not historical user approval. This path is for
  isolated cutover rehearsal until the complete production write surface is
  migrated and its old writer fenced. Queued/ready commands are isolated in Tasks.Readiness; execution is not exposed.
  """

  alias CoopSubstrate.Log
  alias CoopSubstrate.Projections.Tasks, as: State
  alias CoopSubstrate.Protocol.Envelope

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
      # The holder of an operator grant revokes one of their own device grants
      # (docs/architecture/2026-10-19-device-revocation.md).
      "TaskDeviceRevokedV1" =>
        spec("operator", "task_grants", @scope, %{
          "principal_id" => :string,
          "authorization_event_id" => :string,
          "revoked_grant_event_id" => :string
        }),
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
    |> Map.merge(CoopSubstrate.Tasks.DoD.event_types())
    |> Map.merge(CoopSubstrate.Tasks.Readiness.event_types())
    |> Map.merge(CoopSubstrate.Tasks.Timing.event_types())
  end

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

  @doc "Build the unsigned command. Sign with Envelope.sign/3 before submitting."
  def proposal(attrs), do: Envelope.new(Map.put(Map.new(attrs), :type, "TaskProposedV1"))

  @doc "Append durably and return the accepted event/version watermark."
  def propose(command, server \\ Log)

  def propose(%Envelope{type: "TaskProposedV1"} = command, server) do
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

  def propose(_command, _server), do: {:error, :not_a_task_proposal}

  @doc false
  def check(%Envelope{} = env, gate) do
    with :ok <- signer_cardinality(env),
         :ok <- scope_valid(env) do
      cond do
        Map.has_key?(CoopSubstrate.Tasks.Readiness.event_types(), env.type) ->
          CoopSubstrate.Tasks.Readiness.check(env, gate.orchestration, gate.role_keys)

        Map.has_key?(CoopSubstrate.Tasks.DoD.event_types(), env.type) ->
          CoopSubstrate.Tasks.DoD.check(env, gate.orchestration, gate.role_keys)

        Map.has_key?(CoopSubstrate.Tasks.Timing.event_types(), env.type) ->
          CoopSubstrate.Tasks.Timing.check(env, gate.orchestration, gate.role_keys)

        true ->
          check_type(env, gate.orchestration, gate.role_keys)
      end
    end
  end

  # These new governance events require an explicit declared key even while
  # older economic event types retain their original bootstrap semantics.
  defp check_type(%Envelope{type: "TaskOperatorGrantedV1", payload: p} = env, state, keys) do
    with :ok <- governance_declared(env, keys),
         :ok <- nonempty_fields(p, ~w(principal_id key_id)),
         :ok <- device_label(p["device_label"]) do
      if Map.has_key?(state.grants, env.event_id),
        do: {:error, :grant_already_recorded},
        else: :ok
    end
  end

  # Revocation by the holder: from any of their active device grants in the
  # project, of any of their device grants there, itself included.
  defp check_type(%Envelope{type: "TaskDeviceRevokedV1", payload: p} = env, state, _keys) do
    with {:ok, signer_grant} <- fetch_grant(state, p["authorization_event_id"]),
         :ok <- authorized(env, signer_grant),
         {:ok, target} <- fetch_grant(state, p["revoked_grant_event_id"]),
         :ok <- grant_scope(env, target) do
      cond do
        target.principal_id != signer_grant.principal_id -> {:error, :not_own_device}
        not target.active -> {:error, :grant_already_revoked}
        true -> :ok
      end
    end
  end

  defp check_type(%Envelope{type: "TaskOperatorRevokedV1", payload: p} = env, state, keys) do
    with :ok <- governance_declared(env, keys),
         {:ok, grant} <- fetch_grant(state, p["authorization_event_id"]),
         :ok <- grant_scope(env, grant) do
      if grant.active, do: :ok, else: {:error, :grant_already_revoked}
    end
  end

  defp check_type(%Envelope{type: "TaskBaselineRecordedV1", payload: p} = env, state, keys) do
    with :ok <- governance_declared(env, keys),
         :ok <- nonempty_fields(p, ~w(legacy_row_id title definition_of_done)) do
      if Map.has_key?(state.tasks, State.task_key(env)),
        do: {:error, :task_already_recorded},
        else: :ok
    end
  end

  defp check_type(%Envelope{type: "TaskProposedV1", payload: p} = env, state, _keys) do
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

        task.state != "inbox" ->
          {:error, {:invalid_task_transition, task.state, "proposed"}}

        true ->
          :ok
      end
    end
  end

  # Task events admit one accountable governance or operator key. Other event
  # types retain their existing multi-signature rules and canonical bytes.
  defp device_label(nil), do: :ok

  defp device_label(label),
    do: if(String.length(label) in 1..80, do: :ok, else: {:error, :invalid_device_label})

  defp signer_cardinality(%Envelope{signers: [_signer]}), do: :ok
  defp signer_cardinality(_env), do: {:error, :task_signer_cardinality}

  defp scope_valid(env) do
    fields =
      if Map.has_key?(env.payload, "task_id"),
        do: ~w(tenant_id project_id task_id),
        else: ~w(tenant_id project_id)

    values = [env.chapter_id | Enum.map(fields, &env.payload[&1])]
    if Enum.all?(values, &safe_segment?/1), do: :ok, else: {:error, :invalid_task_scope}
  end

  defp safe_segment?(value) do
    is_binary(value) and byte_size(value) in 1..128 and
      Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/, value)
  end

  @doc false
  def nonempty_fields(payload, fields) do
    if Enum.all?(fields, &(String.trim(payload[&1]) != "")),
      do: :ok,
      else: {:error, :empty_task_field}
  end

  @doc false
  def governance_declared(%Envelope{signers: [signer]} = env, keys) do
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

  @doc false
  def authorized(env, grant) do
    with :ok <- grant_scope(env, grant), do: operator_authorized(env, grant)
  end

  defp operator_authorized(%Envelope{signers: [signer]} = env, grant) do
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

  @doc false
  def duplicate([%Envelope{} = env], state) do
    commands =
      state.proposals |> Map.merge(state.dod_commands) |> Map.merge(state.timing_commands)

    case Map.fetch(commands, env.event_id) do
      :error ->
        :new

      {:ok, accepted} ->
        if Envelope.signed_core_term(env) == Envelope.signed_core_term(accepted) and
             env.sigs == accepted.sigs,
           do: {:ok, [accepted]},
           else: {:error, {:reject, 0, :task_command_id_conflict}}
    end
  end

  def duplicate(_batch, _state), do: :new
end
