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
    * Role-key registry (1D) — bootstrap-then-enforce: once a chapter has
      ever declared keys for a role, every signature in that role must match
      a currently declared key (`check_role_keys/2`, runs before every
      per-type check). Genesis (the first governance key) is trust-on-first-
      use, self-certified; later declarations/revocations are governance-
      signed; revoking the last governance key is unrepresentable.
    * `KeyRotated` (1D) — self-rotation: for a REGISTERED member, the
      rotation must be signed by the member's current key and `old_key_id`
      must match it (rotations chain). Rotations for unregistered ids stay
      inert-and-ungated (1A compatibility; ChapterStats still records them).
      Governance-recovery rotation (lost key) is flagged open (08 §10.3).
      Everything else: no log-dependent constraints.
  """

  alias CoopSubstrate.Capital.AccrualRules
  alias CoopSubstrate.Constants
  alias CoopSubstrate.Floor
  alias CoopSubstrate.Membership.Lifecycle
  alias CoopSubstrate.Projections.Membership
  alias CoopSubstrate.Protocol.Envelope
  alias CoopSubstrate.Throughput

  @spec check(Envelope.t(), map()) :: :ok | {:error, term()}
  def check(%Envelope{} = env, gate) do
    with :ok <- check_role_keys(env, gate) do
      type_check(env, gate)
    end
  end

  # Bootstrap-then-enforce (Phase 1D, docs/phase1d_plan.md P4): once a chapter
  # has EVER declared keys for a role, every signature in that role must match
  # a currently declared key. Roles never declared are unchecked (bootstrap
  # mode — the pre-1D behavior, now named). `member` is never in this
  # registry; member keys are checked against the member registry as before.
  defp check_role_keys(%Envelope{signers: signers, chapter_id: ch}, gate) do
    Enum.find_value(signers, :ok, fn signer ->
      case gate.role_keys[{ch, signer.role}] do
        nil ->
          nil

        keys ->
          unless Map.get(keys, signer.key_id) == signer.pubkey do
            {:error, {:role_key_not_declared, signer.role, signer.key_id}}
          end
      end
    end)
  end

  # -- Phase 1D: the role-key registry itself ----------------------------------

  defp type_check(%Envelope{type: "RoleKeyDeclared", chapter_id: ch, payload: p} = env, gate) do
    governance = gate.role_keys[{ch, "governance"}]
    declared = gate.role_keys[{ch, p["role"]}] || %{}

    cond do
      p["role"] not in Constants.declarable_roles() ->
        {:error, {:undeclarable_role, p["role"]}}

      Map.has_key?(declared, p["key_id"]) ->
        {:error, {:role_key_already_declared, p["role"], p["key_id"]}}

      governance == nil and p["role"] != "governance" ->
        # No governance exists yet: the only representable declaration is the
        # genesis governance key itself.
        {:error, :genesis_required}

      governance == nil ->
        # Genesis: trust-on-first-use, self-certified (the MemberRegistered
        # pattern) — flagged in docs/phase1d_plan.md; the mitigation is
        # publishing the genesis checkpoint out-of-band.
        if genesis_self_certified?(env, p) do
          :ok
        else
          {:error, :genesis_must_be_self_signed}
        end

      true ->
        # Post-genesis: the governance-role signature was already validated
        # against the registry by check_role_keys/2.
        :ok
    end
  end

  defp type_check(%Envelope{type: "RoleKeyRevoked", chapter_id: ch, payload: p}, gate) do
    governance = gate.role_keys[{ch, "governance"}]
    declared = gate.role_keys[{ch, p["role"]}] || %{}

    cond do
      governance == nil ->
        {:error, :genesis_required}

      not Map.has_key?(declared, p["key_id"]) ->
        {:error, {:unknown_role_key, p["role"], p["key_id"]}}

      p["role"] == "governance" and map_size(governance) == 1 ->
        # A chapter can never orphan its own governance (P4).
        {:error, :cannot_orphan_governance}

      true ->
        :ok
    end
  end

  # -- Phase 2A: harness events (docs/phase2a_plan.md; corpus 11) --------------

  defp type_check(%Envelope{type: "InterviewConsentGranted", chapter_id: ch, payload: p} = env, gate) do
    {:bytes, pubkey} = p["pubkey"]
    classes = p["classes"]

    cond do
      # One grant per ref; revocation is terminal (re-participation is a new
      # ref) — FLAGGED PLACEHOLDER consent policy.
      Map.has_key?(gate.consents, {ch, p["interviewee_ref"]}) ->
        {:error, {:consent_already_recorded, p["interviewee_ref"]}}

      not (is_list(classes) and classes != [] and
             Enum.all?(classes, &(&1 in Constants.consent_classes()))) ->
        {:error, {:unknown_consent_classes, classes}}

      not Enum.any?(
        env.signers,
        &(&1.role == "interviewee" and &1.pubkey == pubkey and &1.key_id == p["key_id"])
      ) ->
        {:error, :consent_must_be_self_signed}

      true ->
        :ok
    end
  end

  defp type_check(%Envelope{type: "InterviewConsentRevoked", chapter_id: ch, payload: p} = env, gate) do
    case gate.consents[{ch, p["interviewee_ref"]}] do
      nil -> {:error, {:no_consent_recorded, p["interviewee_ref"]}}
      %{active: false} -> {:error, :consent_not_active}
      consent -> check_party_key(env, "interviewee", consent)
    end
  end

  defp type_check(%Envelope{type: "ResearchBriefFiled", payload: p}, _gate) do
    check_section(p["section"])
  end

  defp type_check(%Envelope{type: "InterviewConducted", chapter_id: ch, payload: p}, gate) do
    cond do
      p["section"] not in Constants.harness_sections() ->
        {:error, {:unknown_section, p["section"]}}

      p["mode"] not in Constants.interview_modes() ->
        # voice_agent is structurally absent pending [LEGAL] per state.
        {:error, {:unknown_interview_mode, p["mode"]}}

      Map.has_key?(gate.interviews, {ch, p["interview_id"]}) ->
        {:error, {:interview_already_recorded, p["interview_id"]}}

      not Membership.consent_active?(gate, ch, p["interviewee_ref"]) ->
        {:error, {:no_active_consent, p["interviewee_ref"]}}

      true ->
        :ok
    end
  end

  defp type_check(%Envelope{type: "FindingExtracted", chapter_id: ch, payload: p}, gate) do
    with :ok <- check_interview_source(gate, ch, p["interview_ref"]) do
      cond do
        p["kind"] not in Constants.finding_kinds() ->
          {:error, {:unknown_finding_kind, p["kind"]}}

        Map.has_key?(gate.findings, {ch, p["finding_id"]}) ->
          {:error, {:finding_already_recorded, p["finding_id"]}}

        true ->
          :ok
      end
    end
  end

  defp type_check(%Envelope{type: "DocumentCollected", chapter_id: ch, payload: p}, gate) do
    with :ok <- check_interview_source(gate, ch, p["interview_ref"]) do
      %{interviewee_ref: ref} = gate.interviews[{ch, p["interview_ref"]}]

      cond do
        Map.has_key?(gate.documents, {ch, p["document_id"]}) ->
          {:error, {:document_already_recorded, p["document_id"]}}

        # Recording intake is structural: no recording consent, no recording
        # artifact (Phase 2B P3).
        p["doc_kind"] == "recording" and not gate.consents[{ch, ref}].recording ->
          {:error, {:no_recording_consent, ref}}

        true ->
          :ok
      end
    end
  end

  defp type_check(%Envelope{type: "MachineExtractionRecorded", chapter_id: ch, payload: p}, gate) do
    with :ok <- check_interview_source(gate, ch, p["interview_ref"]) do
      cond do
        Map.has_key?(gate.extractions, {ch, p["proposal_id"]}) ->
          {:error, {:proposal_already_recorded, p["proposal_id"]}}

        # 08 §7 bounded necessity: a frontier model is unrepresentable until
        # its dated migration trigger is declared. FLAGGED PLACEHOLDER:
        # chapter-level any-declaration; per-purpose binding comes with real
        # model use.
        String.starts_with?(p["model_ref"], "frontier:") and
            not Map.get(gate.frontier_declared, ch, false) ->
          {:error, {:frontier_model_undeclared, p["model_ref"]}}

        true ->
          :ok
      end
    end
  end

  defp type_check(%Envelope{type: "ConflictFlagged", chapter_id: ch, payload: p}, gate) do
    with {:ok, _findings} <- resolve_findings(gate, ch, p["finding_refs"]), do: :ok
  end

  defp type_check(%Envelope{type: "Corroborated", chapter_id: ch, payload: p}, gate) do
    with false <- Map.has_key?(gate.corroborations, {ch, p["claim_ref"]}),
         {:ok, findings} <- resolve_findings(gate, ch, p["finding_refs"]) do
      sections = findings |> Enum.map(& &1.section) |> Enum.uniq()

      cond do
        length(sections) != 1 ->
          {:error, :mixed_sections}

        Enum.any?(findings, &(not Membership.consent_active?(gate, ch, &1.interviewee_ref))) ->
          {:error, :no_active_consent}

        true ->
          with {:ok, %{k: k}} <- Membership.harness_constants(gate, ch, hd(sections)) do
            distinct = findings |> Enum.map(& &1.interviewee_ref) |> Enum.uniq() |> length()

            if distinct >= k do
              :ok
            else
              {:error, {:not_independent, distinct, k}}
            end
          end
      end
    else
      true -> {:error, {:already_corroborated, p["claim_ref"]}}
      {:error, _} = error -> error
    end
  end

  defp type_check(%Envelope{type: "InstrumentVersionPublished", chapter_id: ch, payload: p}, gate) do
    with :ok <- check_section(p["section"]) do
      expected = Map.get(gate.instrument_versions, {ch, p["section"]}, 0) + 1

      if p["version"] == expected do
        :ok
      else
        {:error, {:nonmonotonic_instrument_version, p["version"], expected}}
      end
    end
  end

  defp type_check(%Envelope{type: "ProcessModelCompiled", payload: p}, _gate) do
    check_section(p["section"])
  end

  defp type_check(%Envelope{type: "SpecAdopted", chapter_id: ch, payload: p}, gate) do
    with :ok <- check_section(p["section"]) do
      {:bytes, claimed} = p["model_hash"]

      case gate.process_models[{ch, p["section"]}] do
        nil ->
          {:error, {:nothing_compiled, p["section"]}}

        ^claimed ->
          :ok

        _latest ->
          # Adoption must bind the LATEST compiled model — a spec cut from
          # stale evidence is unrepresentable (Phase 2C).
          {:error, {:model_hash_mismatch, p["section"]}}
      end
    end
  end

  defp type_check(%Envelope{type: "FixtureSetPublished", chapter_id: ch, payload: p}, gate) do
    refs = p["source_refs"]

    with :ok <- check_section(p["section"]) do
      cond do
        not (is_list(refs) and refs != [] and Enum.all?(refs, &is_binary/1)) ->
          {:error, :bad_source_refs}

        true ->
          Enum.find_value(refs, :ok, fn interview_id ->
            case gate.interviews[{ch, interview_id}] do
              nil ->
                {:error, {:unknown_interview, interview_id}}

              %{interviewee_ref: ref} ->
                consent = gate.consents[{ch, ref}]

                unless match?(%{active: true}, consent) and
                         "anonymized_fixtures" in consent.classes do
                  {:error, {:fixture_consent_missing, ref}}
                end
            end
          end)
      end
    end
  end

  defp type_check(%Envelope{type: "HonorariumAccrued", chapter_id: ch, payload: p}, gate) do
    cond do
      # Owed for participation regardless of later revocation.
      not Map.has_key?(gate.consents, {ch, p["interviewee_ref"]}) ->
        {:error, {:no_consent_recorded, p["interviewee_ref"]}}

      p["amount_minor"] <= 0 ->
        {:error, :amount_must_be_positive}

      true ->
        :ok
    end
  end

  defp type_check(%Envelope{type: "HonorariumPaid", chapter_id: ch, payload: p}, gate) do
    balance = gate.honoraria[{ch, p["interviewee_ref"]}]

    cond do
      # Counsel clearance as a declared constant; declaring 0 stops payouts
      # again (docs/honorarium_rail.md).
      gate.charter_constants[{ch, "honorarium/payout_cleared"}] != 1 ->
        {:error, :payout_not_cleared}

      balance == nil or balance.accrued == 0 ->
        {:error, {:nothing_accrued, p["interviewee_ref"]}}

      p["amount_minor"] <= 0 ->
        {:error, :amount_must_be_positive}

      balance.paid + p["amount_minor"] > balance.accrued ->
        {:error, {:overpayment, p["interviewee_ref"], balance.accrued - balance.paid}}

      true ->
        :ok
    end
  end

  defp type_check(%Envelope{type: "FrontierModelUseDeclared", payload: p}, _gate) do
    # 08 §7: the migration trigger must be real — dated, with a threshold.
    if p["threshold"] > 0 and byte_size(p["date"]) > 0 and byte_size(p["metric"]) > 0 do
      :ok
    else
      {:error, :bad_migration_trigger}
    end
  end

  defp type_check(%Envelope{type: "FunnelProspectEmitted", chapter_id: ch, payload: p}, gate) do
    interview = gate.interviews[{ch, p["interview_ref"]}]
    consent = gate.consents[{ch, p["interviewee_ref"]}]

    cond do
      Map.has_key?(gate.prospects, {ch, p["prospect_ref"]}) ->
        {:error, {:prospect_already_emitted, p["prospect_ref"]}}

      p["track"] not in Constants.harness_sections() ->
        {:error, {:unknown_track, p["track"]}}

      interview == nil ->
        {:error, {:unknown_interview, p["interview_ref"]}}

      interview.interviewee_ref != p["interviewee_ref"] ->
        {:error, {:interview_interviewee_mismatch, p["interview_ref"]}}

      not match?(%{active: true}, consent) ->
        {:error, {:no_active_consent, p["interviewee_ref"]}}

      "prospect_record" not in consent.classes ->
        {:error, {:prospect_consent_missing, p["interviewee_ref"]}}

      true ->
        :ok
    end
  end

  defp type_check(%Envelope{type: "EscalationRaised", chapter_id: ch, payload: p}, gate) do
    refs = p["packet_refs"]

    cond do
      Map.has_key?(gate.escalations, {ch, p["item_id"]}) ->
        {:error, {:item_already_raised, p["item_id"]}}

      # Decision-ready shape (10 P10; basis resolution is the flagged v0
      # limit — docs/phase5a_plan.md).
      not (is_list(refs) and refs != []) ->
        {:error, :packet_refs_required}

      p["deadline_ms"] <= 0 ->
        {:error, :bad_deadline}

      p["process"] == "" or p["recommendation"] == "" or p["compensation_path"] == "" ->
        {:error, :decision_ready_fields_empty}

      true ->
        # Flooding is structurally bounded (10 §6 adversarial): a declared
        # per-chapter cap on concurrently open items per process; fails
        # closed undeclared.
        case gate.charter_constants[{ch, "cockpit/open_cap"}] do
          cap when is_integer(cap) and cap > 0 ->
            open =
              Enum.count(gate.escalations, fn {{c, _id}, item} ->
                c == ch and item.open and item.process == p["process"]
              end)

            if open < cap do
              :ok
            else
              {:error, {:queue_flooded, p["process"], cap}}
            end

          _ ->
            {:error, :constants_undeclared}
        end
    end
  end

  defp type_check(%Envelope{type: "EscalationResolved", chapter_id: ch, payload: p}, gate) do
    cond do
      p["verdict"] not in ["approved", "declined", "returned_defect"] ->
        {:error, {:unknown_verdict, p["verdict"]}}

      true ->
        case gate.escalations[{ch, p["item_id"]}] do
          nil -> {:error, {:unknown_item, p["item_id"]}}
          %{open: false} -> {:error, {:item_already_resolved, p["item_id"]}}
          %{open: true} -> :ok
        end
    end
  end

  defp type_check(%Envelope{type: "StructuralFindingRaised", chapter_id: ch, payload: p}, gate) do
    cond do
      p["kind"] not in ["b_op_breach", "epsilon_breach", "chronic_override"] ->
        {:error, {:unknown_finding_kind, p["kind"]}}

      Map.has_key?(gate.structural_findings, {ch, p["finding_id"]}) ->
        {:error, {:finding_already_raised, p["finding_id"]}}

      Enum.any?(gate.structural_findings, fn {{c, _id}, finding} ->
        c == ch and finding.kind == p["kind"] and finding.period_ref == p["period_ref"]
      end) ->
        # Exactly-once per (kind, period): a re-run sweep is idempotent by
        # rejection (10 P9; docs/phase5b_plan.md P2).
        {:error, {:finding_exists_for_period, p["kind"], p["period_ref"]}}

      true ->
        :ok
    end
  end

  defp type_check(%Envelope{type: "BuildStarted", chapter_id: ch, payload: p}, gate) do
    with :ok <- check_section(p["section"]),
         {:ok, passed?} <- Membership.harness_gate(gate, ch, p["section"]) do
      if passed?, do: :ok, else: {:error, {:harness_gate_not_passed, p["section"]}}
    end
  end

  defp type_check(%Envelope{type: "KeyRotated", chapter_id: ch, payload: p} = env, gate) do
    case gate.members[{ch, p["member_id"]}] do
      nil ->
        :ok

      %{key_id: current_key_id} = member ->
        if p["old_key_id"] == current_key_id do
          check_party_key(env, "author", member)
        else
          {:error, {:old_key_mismatch, p["old_key_id"], current_key_id}}
        end
    end
  end

  defp type_check(%Envelope{type: "EntityRegistered", chapter_id: ch, payload: p}, gate) do
    cond do
      p["class"] not in Constants.entity_classes() ->
        {:error, {:unknown_entity_class, p["class"]}}

      Map.has_key?(gate.entities, {ch, p["entity_id"]}) ->
        {:error, {:entity_already_registered, p["entity_id"]}}

      true ->
        :ok
    end
  end

  defp type_check(%Envelope{type: "MemberRegistered", chapter_id: ch, payload: p} = env, gate) do
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

  defp type_check(%Envelope{type: "AccrualRuleActivated", payload: p}, _gate) do
    with {:ok, module} <- AccrualRules.fetch(p["rule_id"]) do
      module.validate_params(p["params"])
    end
  end

  defp type_check(%Envelope{type: "PatronageRecorded", chapter_id: ch, payload: p}, gate) do
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

  defp type_check(%Envelope{type: "RedemptionScheduleOpened", chapter_id: ch, payload: p}, gate) do
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

  defp type_check(%Envelope{type: "RedemptionPaid", chapter_id: ch, payload: p}, gate) do
    cond do
      not Map.has_key?(gate.schedules, {ch, p["member_id"], p["entity_id"]}) ->
        {:error, :no_open_schedule}

      p["amount_minor"] <= 0 ->
        {:error, :amount_must_be_positive}

      true ->
        :ok
    end
  end

  defp type_check(%Envelope{type: "SinkingFundContributed", chapter_id: ch, payload: p}, gate) do
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

  defp type_check(%Envelope{type: "ThroughputRuleActivated", payload: p}, _gate) do
    with {:ok, module} <- Throughput.Rules.fetch(p["rule_id"]) do
      module.validate_params(p["params"])
    end
  end

  defp type_check(%Envelope{type: "FloorRuleActivated", payload: p}, _gate) do
    with {:ok, module} <- Floor.Rules.fetch(p["rule_id"]) do
      module.validate_params(p["params"])
    end
  end

  defp type_check(%Envelope{type: "ThroughputRecorded", chapter_id: ch, payload: p}, gate) do
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

  defp type_check(%Envelope{type: "FloorEvaluationRecorded", chapter_id: ch, payload: p}, gate) do
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

  defp type_check(%Envelope{type: "ObligationRecorded", chapter_id: ch, payload: p} = env, gate) do
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

  defp type_check(%Envelope{type: "ObligationAssigned", chapter_id: ch, payload: p} = env, gate) do
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

  defp type_check(%Envelope{type: "ObligationDischarged", chapter_id: ch, payload: p} = env, gate) do
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

  defp type_check(%Envelope{type: type} = env, gate) do
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

  defp check_section(section) do
    if section in Constants.harness_sections() do
      :ok
    else
      {:error, {:unknown_section, section}}
    end
  end

  # Sourcing from an interview requires the interview to exist and its
  # interviewee's consent to be active — post-revocation use is
  # unrepresentable at append (11 P5).
  defp check_interview_source(gate, chapter_id, interview_ref) do
    case gate.interviews[{chapter_id, interview_ref}] do
      nil ->
        {:error, {:unknown_interview, interview_ref}}

      %{interviewee_ref: ref} ->
        if Membership.consent_active?(gate, chapter_id, ref) do
          :ok
        else
          {:error, {:no_active_consent, ref}}
        end
    end
  end

  defp resolve_findings(gate, chapter_id, refs) do
    cond do
      not (is_list(refs) and refs != [] and Enum.all?(refs, &is_binary/1)) ->
        {:error, :bad_finding_refs}

      true ->
        findings = Enum.map(refs, &gate.findings[{chapter_id, &1}])

        if Enum.any?(findings, &is_nil/1) do
          {:error, :unknown_finding}
        else
          {:ok, findings}
        end
    end
  end

  defp genesis_self_certified?(%Envelope{signers: signers}, p) do
    {:bytes, pubkey} = p["pubkey"]

    Enum.any?(
      signers,
      &(&1.role == "governance" and &1.pubkey == pubkey and &1.key_id == p["key_id"])
    )
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
