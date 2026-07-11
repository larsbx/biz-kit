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
      throughput_rules: %{},
      floor_rules: %{},
      obligations: %{},
      role_keys: %{},
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
      escalations: %{}
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

  def handle_event(%Envelope{type: "RedemptionScheduleOpened", chapter_id: ch, payload: p}, state) do
    put_in(state, [:schedules, Access.key({ch, p["member_id"], p["entity_id"]})], %{
      years: p["years"],
      annual_cap_minor: p["annual_cap_minor"],
      method: p["method"]
    })
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

  def handle_event(%Envelope{type: "InstrumentVersionPublished", chapter_id: ch, payload: p}, state) do
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

  def handle_event(%Envelope{type: "MachineExtractionRecorded", chapter_id: ch, payload: p}, state) do
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

  def handle_event(%Envelope{type: "EscalationResolved", chapter_id: ch, payload: p}, state) do
    update_in(state, [:escalations, Access.key({ch, p["item_id"]})], fn item ->
      %{item | open: false}
    end)
  end

  def handle_event(%Envelope{type: type, chapter_id: ch, payload: p} = env, state) do
    if Lifecycle.lifecycle_event?(type) do
      apply_lifecycle(state, ch, p, env)
    else
      state
    end
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
