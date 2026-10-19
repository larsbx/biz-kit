defmodule CoopSubstrate.TaskTimingFixtures do
  @moduledoc """
  Envelope builders for task timing and agent suggestions, shared by the
  scenario tests (through `Log.append/2`) and the property tests (through the
  pure gate). Every builder returns a signed envelope; nothing is appended.
  """

  import CoopSubstrate.LogCase, only: [signed_event: 3]

  @scope %{"tenant_id" => "tenant-1", "project_id" => "project-1"}

  def scope, do: @scope

  # -- timing values -----------------------------------------------------------

  def unscheduled, do: %{"schedule" => nil, "due_ms" => nil}

  def timed(start_ms, duration_ms \\ 3_600_000, due_ms \\ nil) do
    %{
      "schedule" => %{
        "kind" => "timed",
        "start_ms" => start_ms,
        "end_ms" => start_ms + duration_ms,
        "tz" => "Europe/Copenhagen"
      },
      "due_ms" => due_ms
    }
  end

  def all_day(start_date, end_date) do
    %{
      "schedule" => %{"kind" => "all_day", "start_date" => start_date, "end_date" => end_date},
      "due_ms" => nil
    }
  end

  @doc """
  The same key signing under another role tag. Tags only shape the signature
  set; tests use this to show that grants, not tags, separate the roles.
  """
  def as_role(member, role), do: put_in(member, [:signer, :role], role)

  # -- governance --------------------------------------------------------------

  def declare_governance(gov) do
    signed_event(gov, "RoleKeyDeclared", %{
      "role" => "governance",
      "key_id" => gov.signer.key_id,
      "pubkey" => {:bytes, gov.signer.pubkey}
    })
  end

  def operator_grant(gov, operator, principal),
    do: grant(gov, "TaskOperatorGrantedV1", operator, principal)

  def suggester_grant(gov, agent, principal),
    do: grant(gov, "TaskSuggesterGrantedV1", agent, principal)

  def reviewer_grant(gov, reviewer, principal),
    do: grant(gov, "TaskReviewerGrantedV1", reviewer, principal)

  @doc "Governance ends everything `principal` holds in the project."
  def offboard(gov, principal, scope \\ @scope),
    do: signed_event(gov, "TaskPrincipalOffboardedV1", Map.put(scope, "principal_id", principal))

  def suggester_revoke(gov, grant) do
    signed_event(
      gov,
      "TaskSuggesterRevokedV1",
      Map.put(@scope, "authorization_event_id", grant.event_id)
    )
  end

  defp grant(gov, type, key, principal) do
    signed_event(
      gov,
      type,
      Map.merge(@scope, %{
        "principal_id" => principal,
        "key_id" => key.signer.key_id,
        "pubkey" => {:bytes, key.signer.pubkey}
      })
    )
  end

  # -- operator ----------------------------------------------------------------

  @doc """
  The actor fields for a command authorised by `grant`: an operator grant, or a
  delegation, whose delegate principal then acts. A delegated command is signed
  with `as_role(agent, "operator")`: the same command type an operator signs.
  """
  def actor(%{type: "TaskDelegationGrantedV1"} = delegation) do
    %{
      "principal_id" => delegation.payload["delegate_principal_id"],
      "authorization_event_id" => delegation.event_id,
      "lifecycle_version" => 1
    }
  end

  def actor(grant) do
    %{
      "principal_id" => grant.payload["principal_id"],
      "authorization_event_id" => grant.event_id,
      "lifecycle_version" => 1
    }
  end

  def create(op, grant, task_id, timing, opts \\ []) do
    signed_event(
      op,
      "TaskCreatedV1",
      @scope
      |> Map.merge(actor(grant))
      |> Map.merge(%{
        "task_id" => task_id,
        "title" => Keyword.get(opts, :title, "Task #{task_id}"),
        "timing" => timing
      })
      |> put_opt("description", opts[:description])
      |> put_opt("suggestion_event_id", opts[:suggestion])
      |> put_rationale(opts)
    )
  end

  def revise(op, grant, task_id, expected, timing, opts \\ []) do
    signed_event(
      op,
      "TaskTimingRevisedV1",
      @scope
      |> Map.merge(actor(grant))
      |> Map.merge(%{
        "task_id" => task_id,
        "expected_timing_version" => expected,
        "timing" => timing
      })
      |> put_opt("suggestion_event_id", opts[:suggestion])
      |> put_rationale(opts)
    )
  end

  def propose(op, grant, task_id, expected_version) do
    signed_event(
      op,
      "TaskProposedV1",
      @scope
      |> Map.merge(actor(grant))
      |> Map.merge(%{"task_id" => task_id, "expected_version" => expected_version})
    )
  end

  def decline(op, grant, suggestion, opts \\ []) do
    signed_event(
      op,
      "TaskSuggestionDeclinedV1",
      @scope
      |> Map.merge(actor(grant))
      |> Map.merge(%{
        "suggestion_event_id" => id(suggestion),
        "reason" => Keyword.get(opts, :reason, "")
      })
      |> put_opt("reason_receipt_id", opts[:reason_receipt])
    )
  end

  def custody(op, grant, digest) do
    signed_event(
      op,
      "ArtifactCustodyRecordedV1",
      # Custody predates lifecycle versions: its actor is principal and grant only.
      @scope
      |> Map.merge(Map.delete(actor(grant), "lifecycle_version"))
      |> Map.put("artifact_digest", {:bytes, digest})
    )
  end

  @doc "An operator grant for a named device, as enrolment issues it."
  def device_grant(gov, key, principal, label) do
    signed_event(
      gov,
      "TaskOperatorGrantedV1",
      Map.merge(@scope, %{
        "principal_id" => principal,
        "key_id" => key.signer.key_id,
        "pubkey" => {:bytes, key.signer.pubkey},
        "device_label" => label
      })
    )
  end

  @doc "The holder of `grant` revokes `target`, one of their own device grants."
  def device_revoke(op, grant, target) do
    signed_event(
      op,
      "TaskDeviceRevokedV1",
      @scope
      |> Map.merge(Map.delete(actor(grant), "lifecycle_version"))
      |> Map.put("revoked_grant_event_id", target.event_id)
    )
  end

  def operator_revoke(gov, grant) do
    signed_event(
      gov,
      "TaskOperatorRevokedV1",
      Map.put(@scope, "authorization_event_id", grant.event_id)
    )
  end

  # -- delegation --------------------------------------------------------------

  @t0 1_792_396_800_000
  @week 7 * 86_400_000

  @doc "The default delegation window: one week from `t0/0`."
  def t0, do: @t0
  def window, do: %{"not_before_ms" => @t0, "not_after_ms" => @t0 + @week}

  def delegation(op, op_grant, agent, delegate_principal, opts \\ []) do
    signed_event(
      op,
      "TaskDelegationGrantedV1",
      @scope
      |> Map.merge(actor(op_grant))
      |> Map.merge(%{
        "delegate_principal_id" => delegate_principal,
        "key_id" => agent.signer.key_id,
        "pubkey" => {:bytes, agent.signer.pubkey},
        "kinds" => Keyword.get(opts, :kinds, ["timing"]),
        "window" => Keyword.get(opts, :window, window()),
        "max_block_ms" => Keyword.get(opts, :max_block_ms, 4 * 3_600_000),
        "budget" => Keyword.get(opts, :budget, 10)
      })
      |> put_opt("task_ids", opts[:task_ids])
      |> put_opt("states", opts[:states])
    )
  end

  def revoke_delegation(op, op_grant, delegation) do
    signed_event(
      op,
      "TaskDelegationRevokedV1",
      @scope |> Map.merge(actor(op_grant)) |> Map.put("delegation_event_id", delegation.event_id)
    )
  end

  # -- suggester ---------------------------------------------------------------

  def suggester(grant) do
    %{"principal_id" => grant.payload["principal_id"], "authorization_event_id" => grant.event_id}
  end

  def suggest(agent, grant, task_id, change, opts \\ []) do
    signed_event(
      agent,
      "TaskChangeSuggestedV1",
      @scope
      |> Map.merge(suggester(grant))
      |> Map.merge(%{
        "task_id" => task_id,
        "change" => change,
        "rationale" => Keyword.get(opts, :rationale, "Fits the free slot before the deadline")
      })
      |> put_opt("base_timing_version", opts[:base])
      |> put_opt("rationale_receipt_id", opts[:rationale_receipt])
    )
  end

  def timing_change(timing), do: %{"kind" => "timing", "timing" => timing}

  def create_change(title, timing),
    do: %{"kind" => "create", "title" => title, "timing" => timing}

  def withdraw(agent, grant, suggestion, opts \\ []) do
    signed_event(
      agent,
      "TaskSuggestionWithdrawnV1",
      @scope
      |> Map.merge(suggester(grant))
      |> Map.put("suggestion_event_id", id(suggestion))
      |> put_opt("reason", opts[:reason])
      |> put_opt("reason_receipt_id", opts[:reason_receipt])
    )
  end

  def suggestion_artifact(agent, grant, digest) do
    signed_event(
      agent,
      "TaskSuggestionArtifactRecordedV1",
      @scope
      |> Map.merge(Map.delete(actor(grant), "lifecycle_version"))
      |> Map.put("artifact_digest", {:bytes, digest})
    )
  end

  # Store bytes out of log; returns the SHA-256 digest a receipt binds.
  def store!(bytes) do
    {:ok, digest} = CoopSubstrate.Harness.Artifacts.put(bytes)
    digest
  end

  defp id(%{event_id: id}), do: id
  defp id(id) when is_binary(id), do: id

  defp put_rationale(map, opts) do
    map
    |> put_opt("rationale", opts[:rationale])
    |> put_opt("rationale_receipt_id", opts[:rationale_receipt])
  end

  defp put_opt(map, _key, nil), do: map
  defp put_opt(map, key, value), do: Map.put(map, key, id_or(value))

  defp id_or(%{event_id: id}), do: id
  defp id_or(value), do: value
end
