defmodule CoopSubstrate.Projections.Membership do
  @moduledoc """
  The membership projection (Phase 1B, extended in 1C): a chapter-scoped pure
  fold tracking registered entities, registered members (with their *current*
  signing key, following `KeyRotated`), membership records (class + lifecycle
  state), the active accrual/throughput/floor rules per chapter, open
  redemption schedules, and obligation-rail relationships (corpus 05 §1.2:
  current debtor, creditor, terms, open/discharged — never funds).

  This same fold is the **append gate's** state: `CoopSubstrate.Log` holds it
  alongside the chain head, rebuilt from the ledger on recovery and advanced
  on every append, and `CoopSubstrate.Protocol.Validity` checks each incoming
  envelope against it before anything persists. Because the state is a pure
  function of the log prefix, gate decisions are deterministic and
  reproducible by any member from events alone.

  Note the fold never reads log-assigned fields (`global_seq` etc.), so it is
  equally valid over unassigned envelopes — the gate uses this to give later
  events in a batch visibility of earlier ones before assignment.
  """

  @behaviour CoopSubstrate.Projection

  alias CoopSubstrate.Capital.AccrualRules
  alias CoopSubstrate.Membership.Lifecycle
  alias CoopSubstrate.Protocol.Envelope

  @impl true
  def init do
    %{
      entities: %{},
      members: %{},
      memberships: %{},
      active_rules: %{},
      schedules: %{},
      # Phase 7A: the gate's own view of credited − redeemed per
      # (chapter, member, entity), via the same shared rule modules the
      # capital projection uses — the two folds must agree (tested).
      balances: %{},
      throughput_rules: %{},
      floor_rules: %{},
      obligations: %{},
      role_keys: %{},
      # Phase 8A: the dispatch envelope + tender rail. Envelopes keep their
      # version across revocation (10 P6: versioned, atomically revocable —
      # monotonicity survives; `active: false` is the revoked state, never
      # deletion). Tenders track the latest graded parse and the decision.
      dispatch_envelopes: %{},
      tenders: %{},
      # Phase 8B: loads (per-stop lifecycle + status trail, 07 §3 pattern).
      loads: %{},
      # Phase 8C: versioned rate terms (every version kept — dunning follows
      # the version its invoice cites) and the invoicing trail.
      rate_terms: %{},
      invoices: %{},
      # Phase 10A: floor evaluations by evaluation_id (what transitions
      # cite) and the cure anchor — the failing evaluation's at_ms that
      # started the member's current cure.
      floor_evaluations: %{},
      floor_cures: %{},
      # Phase 2A — harness state (docs/phase2a_plan.md). Folds never delete:
      # consent revocation flips `active` and every count below EXCLUDES
      # inactive sources at computation time (11 P5, atomic exclusion).
      consents: %{},
      interviews: %{},
      findings: %{},
      documents: %{},
      corroborations: %{},
      instrument_versions: %{},
      process_models: %{},
      adoptions: %{},
      fixture_sets: %{},
      charter_constants: %{},
      extractions: %{},
      frontier_declared: %{},
      prospects: %{},
      escalations: %{},
      structural_findings: %{},
      honoraria: %{}
    }
  end

  @impl true
  def handle_event(%Envelope{type: "EntityRegistered", chapter_id: ch, payload: p}, state) do
    put_in(state, [:entities, Access.key({ch, p["entity_id"]})], %{
      class: p["class"],
      name: Map.get(p, "name")
    })
  end

  def handle_event(%Envelope{type: "MemberRegistered", chapter_id: ch, payload: p}, state) do
    {:bytes, pubkey} = p["pubkey"]

    put_in(state, [:members, Access.key({ch, p["member_id"]})], %{
      pubkey: pubkey,
      key_id: p["key_id"]
    })
  end

  def handle_event(%Envelope{type: "KeyRotated", chapter_id: ch, payload: p}, state) do
    # KeyRotated predates registration (1A, ungated): only a registered
    # member's current key is updated; rotations for unknown ids are inert
    # here (ChapterStats still records them).
    case state.members[{ch, p["member_id"]}] do
      nil ->
        state

      _member ->
        {:bytes, pubkey} = p["new_pubkey"]

        put_in(state, [:members, Access.key({ch, p["member_id"]})], %{
          pubkey: pubkey,
          key_id: p["new_key_id"]
        })
    end
  end

  def handle_event(%Envelope{type: "KeyRecoveryRotated", chapter_id: ch, payload: p}, state) do
    # 10B: the member's current key changes (the KeyRotated shape) and the
    # authorizing R item is consumed — an old approval can never authorize
    # rolling the member back to a prior key.
    {:bytes, pubkey} = p["new_pubkey"]

    state
    |> put_in([:members, Access.key({ch, p["member_id"]})], %{
      pubkey: pubkey,
      key_id: p["new_key_id"]
    })
    |> update_in([:escalations, Access.key({ch, p["authorization_item_id"]})], fn item ->
      Map.put(item, :consumed, true)
    end)
  end

  def handle_event(%Envelope{type: "AccrualRuleActivated", chapter_id: ch, payload: p}, state) do
    put_in(state, [:active_rules, Access.key(ch)], %{
      rule_id: p["rule_id"],
      params: p["params"]
    })
  end

  def handle_event(%Envelope{type: "RoleKeyDeclared", chapter_id: ch, payload: p}, state) do
    {:bytes, pubkey} = p["pubkey"]

    update_in(state, [:role_keys, Access.key({ch, p["role"]}, %{})], fn keys ->
      Map.put(keys, p["key_id"], pubkey)
    end)
  end

  def handle_event(%Envelope{type: "RoleKeyRevoked", chapter_id: ch, payload: p}, state) do
    # The (possibly empty) map stays: once a role's door closes, it never
    # reopens (docs/phase1d_plan.md P4) — an empty declared set means no
    # signature in that role is acceptable until governance declares a key.
    update_in(state, [:role_keys, Access.key({ch, p["role"]}, %{})], fn keys ->
      Map.delete(keys, p["key_id"])
    end)
  end

  def handle_event(%Envelope{type: "ThroughputRuleActivated", chapter_id: ch, payload: p}, state) do
    put_in(state, [:throughput_rules, Access.key(ch)], %{
      rule_id: p["rule_id"],
      params: p["params"]
    })
  end

  def handle_event(%Envelope{type: "FloorRuleActivated", chapter_id: ch, payload: p}, state) do
    put_in(state, [:floor_rules, Access.key(ch)], %{
      rule_id: p["rule_id"],
      params: p["params"]
    })
  end

  def handle_event(%Envelope{type: "ObligationRecorded", chapter_id: ch, payload: p}, state) do
    put_in(state, [:obligations, Access.key({ch, p["obligation_id"]})], %{
      debtor_id: p["debtor_id"],
      creditor_id: p["creditor_id"],
      amount_minor: p["amount_minor"],
      denomination: p["denomination"],
      open: true
    })
  end

  def handle_event(%Envelope{type: "ObligationAssigned", chapter_id: ch, payload: p}, state) do
    # The gate guarantees the obligation exists and is open.
    update_in(state, [:obligations, Access.key({ch, p["obligation_id"]})], fn ob ->
      %{ob | debtor_id: p["new_debtor_id"]}
    end)
  end

  def handle_event(%Envelope{type: "ObligationDischarged", chapter_id: ch, payload: p}, state) do
    update_in(state, [:obligations, Access.key({ch, p["obligation_id"]})], fn ob ->
      %{ob | open: false}
    end)
  end

  # Phase 9A: an executed netting round closes every open like-denominated
  # pair obligation atomically and opens the residual (docs/phase9a_plan.md).
  def handle_event(%Envelope{type: "NettingExecuted", chapter_id: ch, payload: p}, state) do
    {a, b, denom} = {p["party_a"], p["party_b"], p["denomination"]}

    state =
      update_in(state, [:obligations], fn obligations ->
        Map.new(obligations, fn
          {{^ch, id}, %{open: true, denomination: ^denom} = ob} ->
            if {ob.debtor_id, ob.creditor_id} in [{a, b}, {b, a}] do
              {{ch, id}, %{ob | open: false}}
            else
              {{ch, id}, ob}
            end

          entry ->
            entry
        end)
      end)

    case p["residual_obligation_id"] do
      nil ->
        state

      residual_id ->
        put_in(state, [:obligations, Access.key({ch, residual_id})], %{
          debtor_id: p["net_debtor"],
          creditor_id: p["net_creditor"],
          amount_minor: p["net_minor"],
          denomination: denom,
          open: true
        })
    end
  end

  def handle_event(%Envelope{type: "PatronageRecorded", chapter_id: ch, payload: p}, state) do
    # The gate guarantees an active rule exists and the id is registered
    # (same guarantee the capital projection relies on).
    %{rule_id: rule_id, params: params} = Map.fetch!(state.active_rules, ch)
    {:ok, rule} = AccrualRules.fetch(rule_id)
    credited = rule.credit(params, p["kind"], p["amount_minor"])

    update_in(
      state,
      [:balances, Access.key({ch, p["member_id"], p["entity_id"]}, 0)],
      &(&1 + credited)
    )
  end

  def handle_event(%Envelope{type: "RedemptionScheduleOpened", chapter_id: ch, payload: p}, state) do
    put_in(state, [:schedules, Access.key({ch, p["member_id"], p["entity_id"]})], %{
      years: p["years"],
      annual_cap_minor: p["annual_cap_minor"],
      method: p["method"],
      paid_by_year: %{}
    })
  end

  def handle_event(%Envelope{type: "RedemptionPaid", chapter_id: ch, payload: p}, state) do
    key = {ch, p["member_id"], p["entity_id"]}

    state
    |> update_in([:balances, Access.key(key, 0)], &(&1 - p["amount_minor"]))
    |> update_in([:schedules, Access.key(key), :paid_by_year], fn paid ->
      Map.update(paid, p["year_index"], p["amount_minor"], &(&1 + p["amount_minor"]))
    end)
  end

  # -- Phase 8A: dispatch envelope + tender rail --------------------------------

  def handle_event(%Envelope{type: "EnvelopeDeclared", chapter_id: ch, payload: p}, state) do
    put_in(
      state,
      [:dispatch_envelopes, Access.key({ch, p["member_id"], p["entity_id"], p["scope"]})],
      %{version: p["version"], params: p["params"], active: true}
    )
  end

  def handle_event(%Envelope{type: "EnvelopeRevoked", chapter_id: ch, payload: p}, state) do
    update_in(
      state,
      [:dispatch_envelopes, Access.key({ch, p["member_id"], p["entity_id"], p["scope"]})],
      &%{&1 | active: false}
    )
  end

  def handle_event(%Envelope{type: "TenderReceived", chapter_id: ch, payload: p}, state) do
    {:bytes, raw_ref} = p["raw_ref"]

    put_in(state, [:tenders, Access.key({ch, p["tender_id"]})], %{
      member_id: p["member_id"],
      entity_id: p["entity_id"],
      raw_ref: raw_ref,
      parse: nil,
      decided: nil
    })
  end

  def handle_event(%Envelope{type: "TenderParsed", chapter_id: ch, payload: p}, state) do
    # Latest parse wins: a machine proposal is promotable by a later human
    # parse (08 §7); the decision gate reads only the latest.
    update_in(state, [:tenders, Access.key({ch, p["tender_id"]})], fn tender ->
      %{tender | parse: %{grade: p["grade"], fields: p["fields"]}}
    end)
  end

  def handle_event(%Envelope{type: "TenderAccepted", chapter_id: ch, payload: p}, state) do
    put_in(state, [:tenders, Access.key({ch, p["tender_id"]}), :decided], :accepted)
  end

  def handle_event(%Envelope{type: "TenderDeclined", chapter_id: ch, payload: p}, state) do
    put_in(state, [:tenders, Access.key({ch, p["tender_id"]}), :decided], :declined)
  end

  # -- Phase 8B: dispatch + tracking --------------------------------------------

  def handle_event(%Envelope{type: "LoadDispatched", chapter_id: ch, payload: p}, state) do
    state
    |> put_in([:loads, Access.key({ch, p["load_id"]})], %{
      tender_id: p["tender_id"],
      member_id: p["member_id"],
      entity_id: p["entity_id"],
      stops: %{},
      statuses: []
    })
    |> put_in([:tenders, Access.key({ch, p["tender_id"]}), :dispatched], p["load_id"])
  end

  def handle_event(%Envelope{type: "AppointmentRecorded", chapter_id: ch, payload: p}, state) do
    update_stop(state, ch, p, &Map.put(&1, :appointment_ms, p["appointment_ms"]))
  end

  def handle_event(%Envelope{type: "LoadArrived", chapter_id: ch, payload: p}, state) do
    update_stop(state, ch, p, &Map.put(&1, :arrived_ms, p["occurred_ms"]))
  end

  def handle_event(%Envelope{type: "LoadDeparted", chapter_id: ch, payload: p}, state) do
    update_stop(state, ch, p, &Map.put(&1, :departed_ms, p["occurred_ms"]))
  end

  def handle_event(%Envelope{type: "StatusRecorded", chapter_id: ch, payload: p}, state) do
    update_in(state, [:loads, Access.key({ch, p["load_id"]}), :statuses], fn statuses ->
      statuses ++ [%{status: p["status"], occurred_ms: p["occurred_ms"]}]
    end)
  end

  # -- Phase 8C: invoice, detention, dunning ------------------------------------

  def handle_event(%Envelope{type: "RateTermsDeclared", chapter_id: ch, payload: p}, state) do
    update_in(
      state,
      [
        :rate_terms,
        Access.key({ch, p["member_id"], p["entity_id"]}, %{current: 0, versions: %{}})
      ],
      fn terms ->
        %{current: p["version"], versions: Map.put(terms.versions, p["version"], p["params"])}
      end
    )
  end

  def handle_event(%Envelope{type: "InvoiceIssued", chapter_id: ch, payload: p}, state) do
    state
    |> put_in([:invoices, Access.key({ch, p["invoice_id"]})], %{
      load_id: p["load_id"],
      member_id: p["member_id"],
      entity_id: p["entity_id"],
      terms_version: p["terms_version"],
      amount_minor: p["amount_minor"],
      lines: p["lines"],
      credited_minor: 0,
      memo_ids: [],
      rungs_stepped: 0,
      collection: false
    })
    |> put_in([:loads, Access.key({ch, p["load_id"]}), :invoiced], p["invoice_id"])
  end

  def handle_event(%Envelope{type: "CreditMemoIssued", chapter_id: ch, payload: p}, state) do
    update_in(state, [:invoices, Access.key({ch, p["invoice_id"]})], fn invoice ->
      %{
        invoice
        | credited_minor: invoice.credited_minor + p["amount_minor"],
          memo_ids: invoice.memo_ids ++ [p["memo_id"]]
      }
    end)
  end

  def handle_event(%Envelope{type: "DunningStepped", chapter_id: ch, payload: p}, state) do
    update_in(
      state,
      [:invoices, Access.key({ch, p["invoice_id"]}), :rungs_stepped],
      &(&1 + 1)
    )
  end

  def handle_event(%Envelope{type: "CollectionEscalated", chapter_id: ch, payload: p}, state) do
    put_in(state, [:invoices, Access.key({ch, p["invoice_id"]}), :collection], true)
  end

  # -- Phase 2A: harness events -------------------------------------------------

  def handle_event(%Envelope{type: "InterviewConsentGranted", chapter_id: ch, payload: p}, state) do
    {:bytes, pubkey} = p["pubkey"]

    put_in(state, [:consents, Access.key({ch, p["interviewee_ref"]})], %{
      pubkey: pubkey,
      key_id: p["key_id"],
      classes: p["classes"],
      recording: p["recording"],
      active: true
    })
  end

  def handle_event(%Envelope{type: "InterviewConsentRevoked", chapter_id: ch, payload: p}, state) do
    update_in(state, [:consents, Access.key({ch, p["interviewee_ref"]})], fn consent ->
      %{consent | active: false}
    end)
  end

  def handle_event(%Envelope{type: "InterviewConducted", chapter_id: ch, payload: p}, state) do
    put_in(state, [:interviews, Access.key({ch, p["interview_id"]})], %{
      section: p["section"],
      interviewee_ref: p["interviewee_ref"]
    })
  end

  def handle_event(%Envelope{type: "FindingExtracted", chapter_id: ch, payload: p}, state) do
    # The gate guarantees the interview exists and consent is active.
    interview = Map.fetch!(state.interviews, {ch, p["interview_ref"]})

    put_in(state, [:findings, Access.key({ch, p["finding_id"]})], %{
      interview_ref: p["interview_ref"],
      interviewee_ref: interview.interviewee_ref,
      section: interview.section,
      kind: p["kind"]
    })
  end

  def handle_event(%Envelope{type: "DocumentCollected", chapter_id: ch, payload: p}, state) do
    interview = Map.fetch!(state.interviews, {ch, p["interview_ref"]})

    put_in(state, [:documents, Access.key({ch, p["document_id"]})], %{
      interview_ref: p["interview_ref"],
      interviewee_ref: interview.interviewee_ref,
      section: interview.section
    })
  end

  def handle_event(%Envelope{type: "Corroborated", chapter_id: ch, payload: p}, state) do
    put_in(state, [:corroborations, Access.key({ch, p["claim_ref"]})], p["finding_refs"])
  end

  def handle_event(
        %Envelope{type: "InstrumentVersionPublished", chapter_id: ch, payload: p},
        state
      ) do
    put_in(state, [:instrument_versions, Access.key({ch, p["section"]})], p["version"])
  end

  def handle_event(%Envelope{type: "ProcessModelCompiled", chapter_id: ch, payload: p}, state) do
    # Stores the LATEST model's artifact hash — SpecAdopted binds to it (2C).
    {:bytes, artifact_hash} = p["artifact_hash"]
    put_in(state, [:process_models, Access.key({ch, p["section"]})], artifact_hash)
  end

  def handle_event(%Envelope{type: "SpecAdopted", chapter_id: ch, payload: p}, state) do
    put_in(state, [:adoptions, Access.key({ch, p["section"]})], true)
  end

  def handle_event(%Envelope{type: "FixtureSetPublished", chapter_id: ch, payload: p}, state) do
    put_in(state, [:fixture_sets, Access.key({ch, p["section"]})], true)
  end

  def handle_event(%Envelope{type: "CharterConstantDeclared", chapter_id: ch, payload: p}, state) do
    put_in(state, [:charter_constants, Access.key({ch, p["name"]})], p["value"])
  end

  def handle_event(
        %Envelope{type: "MachineExtractionRecorded", chapter_id: ch, payload: p},
        state
      ) do
    put_in(state, [:extractions, Access.key({ch, p["proposal_id"]})], %{
      interview_ref: p["interview_ref"]
    })
  end

  def handle_event(%Envelope{type: "FrontierModelUseDeclared", chapter_id: ch}, state) do
    put_in(state, [:frontier_declared, Access.key(ch)], true)
  end

  def handle_event(%Envelope{type: "FunnelProspectEmitted", chapter_id: ch, payload: p}, state) do
    put_in(state, [:prospects, Access.key({ch, p["prospect_ref"]})], %{
      interviewee_ref: p["interviewee_ref"]
    })
  end

  def handle_event(%Envelope{type: "EscalationRaised", chapter_id: ch, payload: p}, state) do
    put_in(state, [:escalations, Access.key({ch, p["item_id"]})], %{
      process: p["process"],
      act_type: p["act_type"],
      deadline_ms: p["deadline_ms"],
      recommendation: p["recommendation"],
      open: true
    })
  end

  def handle_event(%Envelope{type: "EscalationResolved", chapter_id: ch, payload: p} = env, state) do
    update_in(state, [:escalations, Access.key({ch, p["item_id"]})], fn item ->
      item
      |> Map.put(:open, false)
      |> Map.put(:verdict, p["verdict"])
      |> Map.put(:resolved_ms, env.timestamp_ms)
    end)
  end

  def handle_event(%Envelope{type: "HonorariumAccrued", chapter_id: ch, payload: p}, state) do
    update_in(
      state,
      [:honoraria, Access.key({ch, p["interviewee_ref"]}, %{accrued: 0, paid: 0})],
      &%{&1 | accrued: &1.accrued + p["amount_minor"]}
    )
  end

  def handle_event(%Envelope{type: "HonorariumPaid", chapter_id: ch, payload: p}, state) do
    update_in(
      state,
      [:honoraria, Access.key({ch, p["interviewee_ref"]}, %{accrued: 0, paid: 0})],
      &%{&1 | paid: &1.paid + p["amount_minor"]}
    )
  end

  def handle_event(%Envelope{type: "StructuralFindingRaised", chapter_id: ch, payload: p}, state) do
    put_in(state, [:structural_findings, Access.key({ch, p["finding_id"]})], %{
      kind: p["kind"],
      period_ref: p["period_ref"]
    })
  end

  # -- Phase 10A: evidenced floor transitions -----------------------------------

  def handle_event(%Envelope{type: "FloorEvaluationRecorded", chapter_id: ch, payload: p}, state) do
    put_in(state, [:floor_evaluations, Access.key({ch, p["evaluation_id"]})], %{
      member_id: p["member_id"],
      entity_id: p["entity_id"],
      cleared: p["cleared"],
      at_ms: p["at_ms"]
    })
  end

  def handle_event(%Envelope{type: "FloorCureStarted", chapter_id: ch, payload: p} = env, state) do
    # The gate guarantees the cited evaluation exists, matches, and fails.
    %{at_ms: at_ms} = state.floor_evaluations[{ch, p["evaluation_ref"]}]

    state
    |> put_in([:floor_cures, Access.key({ch, p["member_id"], p["entity_id"]})], at_ms)
    |> apply_lifecycle(ch, p, env)
  end

  def handle_event(%Envelope{type: type, chapter_id: ch, payload: p} = env, state)
      when type in ["FloorCureCleared", "MembershipFloorExited"] do
    # Leaving in_cure clears the anchor; a later cure round starts fresh.
    state
    |> update_in([:floor_cures], &Map.delete(&1, {ch, p["member_id"], p["entity_id"]}))
    |> apply_lifecycle(ch, p, env)
  end

  def handle_event(%Envelope{type: type, chapter_id: ch, payload: p} = env, state) do
    if Lifecycle.lifecycle_event?(type) do
      apply_lifecycle(state, ch, p, env)
    else
      state
    end
  end

  defp update_stop(state, ch, p, fun) do
    update_in(state, [:loads, Access.key({ch, p["load_id"]}), :stops], fn stops ->
      Map.update(stops, p["stop"], fun.(%{}), fun)
    end)
  end

  defp apply_lifecycle(state, ch, p, %Envelope{type: type} = _env) do
    key = {ch, p["member_id"], p["entity_id"]}
    current = state.memberships[key]

    case Lifecycle.apply(current && current.state, type) do
      {:ok, next} ->
        record = %{
          class: (current && current.class) || Map.get(p, "class"),
          state: next
        }

        put_in(state, [:memberships, Access.key(key)], record)

      {:error, _illegal} ->
        # The gate rejects illegal transitions before persistence, so this
        # branch is unreachable for a gated log; the fold stays total (and
        # deterministic) regardless.
        state
    end
  end

  # -- queries -----------------------------------------------------------------

  @doc "The membership record for (chapter, member, entity), or nil."
  def membership(state, chapter_id, member_id, entity_id) do
    state.memberships[{chapter_id, member_id, entity_id}]
  end

  @doc "All of one member's memberships in a chapter: `[{entity_id, record}]`."
  def memberships_of(state, chapter_id, member_id) do
    for {{^chapter_id, ^member_id, entity_id}, record} <- state.memberships do
      {entity_id, record}
    end
  end

  @doc "The gate's remaining balance (credited − redeemed) for (chapter, member, entity)."
  def balance(state, chapter_id, member_id, entity_id) do
    Map.get(state.balances, {chapter_id, member_id, entity_id}, 0)
  end

  @doc "The member's dispatch envelope record for a scope, or nil (8A)."
  def dispatch_envelope(state, chapter_id, member_id, entity_id, scope) do
    state.dispatch_envelopes[{chapter_id, member_id, entity_id, scope}]
  end

  # -- Phase 2A: the harness gate (corpus 11 §2) -------------------------------

  @doc """
  `gate(section)` as a pure function of the fold: interviews ≥ n ∧
  corroborated core ≥ c ∧ documents ≥ d ∧ adopted ∧ fixtures — every count
  excluding revoked sources at computation time. Fails closed with
  `:constants_undeclared` until `n/c/d` (and the corroboration threshold
  `k`) arrive via `CharterConstantDeclared`.
  """
  def harness_gate(state, chapter_id, section) do
    with {:ok, constants} <- harness_constants(state, chapter_id, section) do
      counts = harness_counts(state, chapter_id, section, constants.k)

      {:ok,
       counts.interviews >= constants.n and counts.corroborated >= constants.c and
         counts.documents >= constants.d and counts.adopted and counts.fixtures}
    end
  end

  @doc "The declared gate constants for a section, or :constants_undeclared."
  def harness_constants(state, chapter_id, section) do
    [n, c, d] =
      section
      |> CoopSubstrate.Constants.harness_gate_constants()
      |> Enum.map(&state.charter_constants[{chapter_id, &1}])

    k = state.charter_constants[{chapter_id, "k"}]

    if Enum.all?([n, c, d, k], &(is_integer(&1) and &1 > 0)) do
      {:ok, %{n: n, c: c, d: d, k: k}}
    else
      {:error, :constants_undeclared}
    end
  end

  @doc "Per-section gate inputs, revocation-excluded (11 P5)."
  def harness_counts(state, chapter_id, section, k) do
    interviews =
      Enum.count(state.interviews, fn {{ch, _id}, interview} ->
        ch == chapter_id and interview.section == section and
          consent_active?(state, chapter_id, interview.interviewee_ref)
      end)

    documents =
      Enum.count(state.documents, fn {{ch, _id}, document} ->
        ch == chapter_id and document.section == section and
          consent_active?(state, chapter_id, document.interviewee_ref)
      end)

    corroborated =
      Enum.count(state.corroborations, fn {{ch, _claim}, finding_refs} ->
        ch == chapter_id and
          surviving_sources(state, chapter_id, section, finding_refs) >= k
      end)

    %{
      interviews: interviews,
      documents: documents,
      corroborated: corroborated,
      adopted: Map.get(state.adoptions, {chapter_id, section}, false),
      fixtures: Map.get(state.fixture_sets, {chapter_id, section}, false)
    }
  end

  @doc "Is this interviewee's consent granted and not revoked?"
  def consent_active?(state, chapter_id, interviewee_ref) do
    match?(%{active: true}, state.consents[{chapter_id, interviewee_ref}])
  end

  # Distinct consent-active interviewees behind a claim's findings — a
  # revoked source stops counting toward corroboration (11 P5).
  defp surviving_sources(state, chapter_id, section, finding_refs) do
    finding_refs
    |> Enum.map(&state.findings[{chapter_id, &1}])
    |> Enum.filter(fn finding ->
      finding != nil and finding.section == section and
        consent_active?(state, chapter_id, finding.interviewee_ref)
    end)
    |> Enum.map(& &1.interviewee_ref)
    |> Enum.uniq()
    |> length()
  end
end
