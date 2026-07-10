defmodule CoopSubstrate.Protocol.Validity do
  @moduledoc """
  Log-dependent validity (Phase 1B) — the realization of the 1A registry
  hook (09 gated-N): whether an envelope is acceptable can depend on prior
  log events. Checked at the append gate, before persistence, against the
  gate state (a `CoopSubstrate.Projections.Membership` fold of the log
  prefix, plus earlier events in the same batch), so illegal facts never
  enter the eternal log.

  Checks per type:

    * `EntityRegistered` — known class, id not already registered.
    * `MemberRegistered` — id not already registered; self-certifying: the
      declared `member`-role signer must be exactly the registered
      (pubkey, key_id).
    * Membership lifecycle events — member and entity registered; transition
      legal per `Membership.Lifecycle`; invited class matches the entity's;
      and every `member`-role signature must come from the member's
      *currently registered* key (steward keys have no registry yet — 1D).
    * `AccrualRuleActivated` — rule known to the code registry, params valid.
    * `PatronageRecorded` — active membership (PLACEHOLDER: probationary
      counts), an active accrual rule for the chapter, positive amount.
    * `RedemptionScheduleOpened` — membership in a terminal (redeemable)
      state; no schedule already open; positive years/cap; known method.
    * `RedemptionPaid` — schedule open; positive amount. (Amount-vs-balance
      and annual-cap enforcement are deferred workflow — see the plan.)
    * `SinkingFundContributed` — entity registered; positive amount.
    * `ThroughputRuleActivated` / `FloorRuleActivated` (1C) — rule known to
      the code registry, params valid.
    * `ThroughputRecorded` (1C) — active membership; component in the closed
      set; positive units and occurred_ms; an active throughput rule.
    * `FloorEvaluationRecorded` (1C) — membership exists, not in hardship
      (hardship suspends the floor); rule_id is the chapter's active floor
      rule; sane window/value.
    * Obligation rail (1C, corpus 05 §1.2) — parties registered and distinct,
      signing with their *current* keys; obligation ids unique; assignment
      and discharge only on open obligations; discharge-once. No event
      represents fund movement (05 P11) — settlement is attestation only.
    * `KeyRotated` stays ungated (1A compatibility; rotation governance is
      1D). Everything else: no log-dependent constraints.
  """

  alias CoopSubstrate.Capital.AccrualRules
  alias CoopSubstrate.Constants
  alias CoopSubstrate.Floor
  alias CoopSubstrate.Membership.Lifecycle
  alias CoopSubstrate.Projections.Membership
  alias CoopSubstrate.Protocol.Envelope
  alias CoopSubstrate.Throughput

  @spec check(Envelope.t(), map()) :: :ok | {:error, term()}
  def check(%Envelope{type: "EntityRegistered", chapter_id: ch, payload: p}, gate) do
    cond do
      p["class"] not in Constants.entity_classes() ->
        {:error, {:unknown_entity_class, p["class"]}}

      Map.has_key?(gate.entities, {ch, p["entity_id"]}) ->
        {:error, {:entity_already_registered, p["entity_id"]}}

      true ->
        :ok
    end
  end

  def check(%Envelope{type: "MemberRegistered", chapter_id: ch, payload: p} = env, gate) do
    {:bytes, pubkey} = p["pubkey"]

    cond do
      Map.has_key?(gate.members, {ch, p["member_id"]}) ->
        {:error, {:member_already_registered, p["member_id"]}}

      not Enum.any?(
        env.signers,
        &(&1.role == "member" and &1.pubkey == pubkey and &1.key_id == p["key_id"])
      ) ->
        {:error, :registration_must_be_self_signed}

      true ->
        :ok
    end
  end

  def check(%Envelope{type: "AccrualRuleActivated", payload: p}, _gate) do
    with {:ok, module} <- AccrualRules.fetch(p["rule_id"]) do
      module.validate_params(p["params"])
    end
  end

  def check(%Envelope{type: "PatronageRecorded", chapter_id: ch, payload: p}, gate) do
    record = Membership.membership(gate, ch, p["member_id"], p["entity_id"])

    cond do
      record == nil ->
        {:error, {:no_membership, p["member_id"], p["entity_id"]}}

      not Lifecycle.active?(record.state) ->
        {:error, {:membership_not_active, record.state}}

      not Map.has_key?(gate.active_rules, ch) ->
        {:error, {:no_active_accrual_rule, ch}}

      p["amount_minor"] <= 0 ->
        {:error, :amount_must_be_positive}

      true ->
        :ok
    end
  end

  def check(%Envelope{type: "RedemptionScheduleOpened", chapter_id: ch, payload: p}, gate) do
    record = Membership.membership(gate, ch, p["member_id"], p["entity_id"])

    cond do
      record == nil ->
        {:error, {:no_membership, p["member_id"], p["entity_id"]}}

      not Lifecycle.terminal?(record.state) ->
        {:error, {:account_not_redeemable, record.state}}

      Map.has_key?(gate.schedules, {ch, p["member_id"], p["entity_id"]}) ->
        {:error, :schedule_already_open}

      p["years"] <= 0 or p["annual_cap_minor"] <= 0 ->
        {:error, :bad_schedule_terms}

      p["method"] not in Constants.redemption_methods() ->
        {:error, {:unknown_redemption_method, p["method"]}}

      true ->
        :ok
    end
  end

  def check(%Envelope{type: "RedemptionPaid", chapter_id: ch, payload: p}, gate) do
    cond do
      not Map.has_key?(gate.schedules, {ch, p["member_id"], p["entity_id"]}) ->
        {:error, :no_open_schedule}

      p["amount_minor"] <= 0 ->
        {:error, :amount_must_be_positive}

      true ->
        :ok
    end
  end

  def check(%Envelope{type: "SinkingFundContributed", chapter_id: ch, payload: p}, gate) do
    cond do
      not Map.has_key?(gate.entities, {ch, p["entity_id"]}) ->
        {:error, {:unregistered_entity, p["entity_id"]}}

      p["amount_minor"] <= 0 ->
        {:error, :amount_must_be_positive}

      true ->
        :ok
    end
  end

  # -- Phase 1C: throughput & floor (docs/phase1c_plan.md step 4) --------------

  def check(%Envelope{type: "ThroughputRuleActivated", payload: p}, _gate) do
    with {:ok, module} <- Throughput.Rules.fetch(p["rule_id"]) do
      module.validate_params(p["params"])
    end
  end

  def check(%Envelope{type: "FloorRuleActivated", payload: p}, _gate) do
    with {:ok, module} <- Floor.Rules.fetch(p["rule_id"]) do
      module.validate_params(p["params"])
    end
  end

  def check(%Envelope{type: "ThroughputRecorded", chapter_id: ch, payload: p}, gate) do
    record = Membership.membership(gate, ch, p["member_id"], p["entity_id"])

    cond do
      record == nil ->
        {:error, {:no_membership, p["member_id"], p["entity_id"]}}

      not Lifecycle.active?(record.state) ->
        {:error, {:membership_not_active, record.state}}

      p["component"] not in Constants.throughput_components() ->
        {:error, {:unknown_component, p["component"]}}

      p["units"] <= 0 ->
        {:error, :units_must_be_positive}

      p["occurred_ms"] <= 0 ->
        {:error, :bad_occurred_ms}

      not Map.has_key?(gate.throughput_rules, ch) ->
        {:error, {:no_active_throughput_rule, ch}}

      true ->
        :ok
    end
  end

  def check(%Envelope{type: "FloorEvaluationRecorded", chapter_id: ch, payload: p}, gate) do
    record = Membership.membership(gate, ch, p["member_id"], p["entity_id"])
    active = gate.floor_rules[ch]

    cond do
      record == nil ->
        {:error, {:no_membership, p["member_id"], p["entity_id"]}}

      Lifecycle.floor_suspended?(record.state) ->
        {:error, :floor_suspended_by_hardship}

      active == nil ->
        {:error, {:no_active_floor_rule, ch}}

      p["rule_id"] != active.rule_id ->
        {:error, {:not_the_active_floor_rule, p["rule_id"]}}

      p["window_ms"] <= 0 ->
        {:error, :bad_window}

      p["value"] < 0 ->
        {:error, :bad_value}

      true ->
        :ok
    end
  end

  # -- Phase 1C: the obligation rail (corpus 05 §1.2; P11 — attestation, never
  # funds). Party signatures must use each party's CURRENT registered key,
  # following rotation, exactly as membership events do. ------------------------

  def check(%Envelope{type: "ObligationRecorded", chapter_id: ch, payload: p} = env, gate) do
    debtor = gate.members[{ch, p["debtor_id"]}]
    creditor = gate.members[{ch, p["creditor_id"]}]

    cond do
      Map.has_key?(gate.obligations, {ch, p["obligation_id"]}) ->
        {:error, {:obligation_already_recorded, p["obligation_id"]}}

      p["debtor_id"] == p["creditor_id"] ->
        {:error, :self_obligation}

      debtor == nil ->
        {:error, {:unregistered_member, p["debtor_id"]}}

      creditor == nil ->
        {:error, {:unregistered_member, p["creditor_id"]}}

      p["amount_minor"] <= 0 ->
        {:error, :amount_must_be_positive}

      true ->
        with :ok <- check_party_key(env, "debtor", debtor) do
          check_party_key(env, "creditor", creditor)
        end
    end
  end

  def check(%Envelope{type: "ObligationAssigned", chapter_id: ch, payload: p} = env, gate) do
    obligation = gate.obligations[{ch, p["obligation_id"]}]
    assignee = gate.members[{ch, p["new_debtor_id"]}]

    cond do
      obligation == nil ->
        {:error, {:no_such_obligation, p["obligation_id"]}}

      not obligation.open ->
        {:error, :obligation_discharged}

      assignee == nil ->
        {:error, {:unregistered_member, p["new_debtor_id"]}}

      p["new_debtor_id"] == obligation.creditor_id ->
        {:error, :self_obligation}

      true ->
        with :ok <- check_party_key(env, "assignor", gate.members[{ch, obligation.debtor_id}]) do
          check_party_key(env, "assignee", assignee)
        end
    end
  end

  def check(%Envelope{type: "ObligationDischarged", chapter_id: ch, payload: p} = env, gate) do
    case gate.obligations[{ch, p["obligation_id"]}] do
      nil ->
        {:error, {:no_such_obligation, p["obligation_id"]}}

      %{open: false} ->
        {:error, :obligation_discharged}

      %{debtor_id: debtor_id, creditor_id: creditor_id} ->
        with :ok <- check_party_key(env, "debtor", gate.members[{ch, debtor_id}]) do
          check_party_key(env, "creditor", gate.members[{ch, creditor_id}])
        end
    end
  end

  def check(%Envelope{type: type} = env, gate) do
    if Lifecycle.lifecycle_event?(type) do
      check_lifecycle(env, gate)
    else
      :ok
    end
  end

  defp check_lifecycle(%Envelope{type: type, chapter_id: ch, payload: p} = env, gate) do
    member_key = {ch, p["member_id"]}
    entity = gate.entities[{ch, p["entity_id"]}]
    record = Membership.membership(gate, ch, p["member_id"], p["entity_id"])

    cond do
      not Map.has_key?(gate.members, member_key) ->
        {:error, {:unregistered_member, p["member_id"]}}

      entity == nil ->
        {:error, {:unregistered_entity, p["entity_id"]}}

      type == "MembershipInvited" and p["class"] != entity.class ->
        {:error, {:class_mismatch, p["class"], entity.class}}

      true ->
        with {:ok, _next} <- Lifecycle.apply(record && record.state, type) do
          check_member_signature(env, gate.members[member_key])
        end
    end
  end

  # Every member-role signer on a lifecycle event must be the member's
  # currently registered key — a signature from a stale or foreign key is
  # rejected even though it is cryptographically valid.
  defp check_member_signature(%Envelope{signers: signers}, %{pubkey: pubkey, key_id: key_id}) do
    signers
    |> Enum.filter(&(&1.role == "member"))
    |> Enum.find_value(:ok, fn signer ->
      unless signer.pubkey == pubkey and signer.key_id == key_id do
        {:error, {:not_the_members_current_key, signer.key_id}}
      end
    end)
  end

  # Same discipline for obligation-rail parties: every signer carrying the
  # role must be that party's currently registered key.
  defp check_party_key(%Envelope{signers: signers}, role, %{pubkey: pubkey, key_id: key_id}) do
    signers
    |> Enum.filter(&(&1.role == role))
    |> Enum.find_value(:ok, fn signer ->
      unless signer.pubkey == pubkey and signer.key_id == key_id do
        {:error, {:wrong_key_for_role, role, signer.key_id}}
      end
    end)
  end
end
