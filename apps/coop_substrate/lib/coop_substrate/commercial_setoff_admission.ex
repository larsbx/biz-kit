defmodule CoopSubstrate.CommercialSetoffAdmission do
  @moduledoc """
  Source-bound accounting review in the canonical business log. A successful
  admission reserves the cited sources and records an accounting review receipt.
  It leaves balances and obligations open.

  The chapter opts into the review profile with its registered governance key.
  Three independent registered reviewers attest scoped corporate authority for
  each party and a documented non-prohibition determination. Those attestations
  are accountable inputs from external review, not legal conclusions of the log.
  """

  alias CoopSubstrate.{Canonical, CommercialSourceLineage, Finance}
  alias CoopSubstrate.Protocol.Envelope

  @profile "CommercialSetoffReviewProfileEnabledV2"
  @evidence "CommercialSetoffReviewEvidenceRecordedV2"
  @revoke "CommercialSetoffReviewEvidenceRevokedV2"
  @admit "CommercialSetoffAdmittedV2"
  @reviewer "commercial_setoff_reviewer"
  @max_minor 9_223_372_036_854_775_807

  def event_types do
    %{
      @profile => spec(["governance"], "commercial-setoff-profile", %{}),
      @evidence =>
        spec([@reviewer], "commercial-setoff-review-evidence", %{
          "kind" => :string,
          "subject_id" => :string,
          "terms_digest" => :hash,
          "record_digest" => :hash,
          "not_before_ms" => :int,
          "expires_at_ms" => :int
        }),
      @revoke =>
        spec(["governance"], "commercial-setoff-review-evidence", %{
          "evidence_id" => :string
        }),
      @admit =>
        spec(["party_a", "party_b"], "commercial-setoff-admissions", %{
          "intent_id" => :string,
          "party_a" => :string,
          "party_b" => :string,
          "denomination" => :string,
          "sources" => :any,
          "a_to_b" => :int,
          "b_to_a" => :int,
          "setoff" => :int,
          "residual_minor" => :int,
          "grant_a_id" => :string,
          "grant_b_id" => :string,
          "non_prohibition_id" => :string
        })
    }
  end

  defp spec(roles, stream, required) do
    %{
      required_roles: roles,
      disclosure_class: :bilateral,
      stream: {:chapter_scoped, stream},
      payload: %{required: required, optional: %{}}
    }
  end

  @doc "Build the exact terms that must be approved and signed by both participants."
  def terms(gate, chapter, {a, b}, denomination, intent_id)
      when is_binary(a) and a != "" and is_binary(b) and a < b and
             is_binary(denomination) and is_binary(intent_id) do
    rows =
      for {{^chapter, id}, %{open: true, denomination: ^denomination} = ob} <- gate.obligations,
          {ob.debtor_id, ob.creditor_id} in [{a, b}, {b, a}],
          do: {id, ob}

    with true <- Regex.match?(~r/\A[A-Z]{3}\z/, denomination),
         true <- Regex.match?(~r/\A[A-Za-z0-9_-]{1,128}\z/, intent_id),
         true <- length(rows) in 2..256,
         {:ok, sources} <- source_terms(rows, gate, chapter),
         obligations <- Map.new(rows, fn {id, ob} -> {{chapter, id}, ob} end),
         [%{a_to_b: ab, b_to_a: ba, setoff: setoff}] <-
           Finance.compute(obligations, chapter, {a, b}),
         true <- setoff > 0 and max(ab, ba) <= @max_minor do
      {:ok,
       %{
         "intent_id" => intent_id,
         "party_a" => a,
         "party_b" => b,
         "denomination" => denomination,
         "sources" => sources,
         "a_to_b" => ab,
         "b_to_a" => ba,
         "setoff" => setoff,
         "residual_minor" => ab - ba
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_commercial_setoff_terms}
    end
  end

  def terms(_, _, _, _, _), do: {:error, :invalid_commercial_setoff_terms}

  @doc "Digest scoped to this event version, chapter and exact accounting terms."
  def terms_digest(gate, chapter, terms) do
    with %{key_id: a_key, pubkey: a_pub} <- gate.members[{chapter, terms["party_a"]}],
         %{key_id: b_key, pubkey: b_pub} <- gate.members[{chapter, terms["party_b"]}],
         {:ok, digest} <-
           Canonical.hash([
             @admit,
             chapter,
             terms,
             [a_key, {:bytes, a_pub}, member_key_epoch(gate, chapter, terms["party_a"])],
             [b_key, {:bytes, b_pub}, member_key_epoch(gate, chapter, terms["party_b"])]
           ]) do
      {:ok, {:bytes, digest}}
    else
      _ -> {:error, :invalid_commercial_participant_consent}
    end
  end

  defp source_terms(rows, gate, chapter) do
    rows
    |> Enum.sort_by(&elem(&1, 0), :desc)
    |> Enum.reduce_while({:ok, []}, fn {id, ob}, {:ok, acc} ->
      lineage = gate.commercial_source_lineage[{chapter, id}]

      cond do
        not CommercialSourceLineage.original_only?(gate, chapter, id) ->
          {:halt, {:error, {:ineligible_commercial_source, id}}}

        Map.has_key?(gate.commercial_setoff_admission.claims, {chapter, id}) ->
          {:halt, {:error, {:commercial_source_reserved, id}}}

        true ->
          source = %{
            "obligation_id" => id,
            "revision" => lineage.source_revision,
            "signed_core_digest" => {:bytes, lineage.original_signed_core_digest},
            "debtor_id" => ob.debtor_id,
            "creditor_id" => ob.creditor_id,
            "denomination" => ob.denomination,
            "amount_minor" => ob.amount_minor
          }

          {:cont, {:ok, [source | acc]}}
      end
    end)
  end

  def init do
    %{profiles: MapSet.new(), evidence: %{}, admissions: %{}, claims: %{}, member_key_epochs: %{}}
  end

  defp member_key_epoch(gate, chapter, member) do
    Map.get(gate.commercial_setoff_admission.member_key_epochs, {chapter, member}, 0)
  end

  def rotate_member_key(state, chapter, member) do
    update_in(state.commercial_setoff_admission.member_key_epochs, fn epochs ->
      Map.update(epochs, {chapter, member}, 1, &(&1 + 1))
    end)
  end

  def check(%Envelope{} = env, gate), do: check(env, gate, System.system_time(:millisecond))

  def check(%Envelope{type: @profile, chapter_id: ch} = env, gate, _now) do
    with :ok <- registered_signer(env, gate, "governance"),
         false <- protected?(gate, ch) do
      :ok
    else
      _ -> {:error, :invalid_commercial_review_profile}
    end
  end

  def check(%Envelope{type: @evidence, chapter_id: ch, payload: p} = env, gate, now) do
    with true <- protected?(gate, ch),
         :ok <- registered_signer(env, gate, @reviewer),
         true <- evidence_subject?(p, gate, ch),
         true <- p["not_before_ms"] >= 0 and p["not_before_ms"] < p["expires_at_ms"],
         true <- now < p["expires_at_ms"],
         false <- Map.has_key?(gate.commercial_setoff_admission.evidence, {ch, env.event_id}) do
      :ok
    else
      _ -> {:error, :invalid_commercial_review_evidence}
    end
  end

  def check(%Envelope{type: @revoke, chapter_id: ch, payload: p} = env, gate, _now) do
    with :ok <- registered_signer(env, gate, "governance"),
         %{active: true} <- gate.commercial_setoff_admission.evidence[{ch, p["evidence_id"]}] do
      :ok
    else
      _ -> {:error, :invalid_commercial_review_revocation}
    end
  end

  def check(%Envelope{type: @admit, chapter_id: ch, payload: p} = env, gate, now) do
    with :ok <- require_profile(gate, ch),
         :ok <- fresh_intent(gate, ch, p["intent_id"]),
         :ok <- current_parties(env, gate),
         {:ok, terms} <-
           terms(gate, ch, {p["party_a"], p["party_b"]}, p["denomination"], p["intent_id"]),
         true <- terms === Map.drop(p, ~w(grant_a_id grant_b_id non_prohibition_id)),
         {:ok, digest} <- terms_digest(gate, ch, terms) do
      current_evidence(env, gate, digest, now)
    else
      false -> {:error, :commercial_setoff_terms_mismatch}
      {:error, _} = error -> error
    end
  end

  defp require_profile(gate, ch) do
    if protected?(gate, ch), do: :ok, else: {:error, :commercial_review_profile_required}
  end

  defp fresh_intent(gate, ch, id) do
    if Map.has_key?(gate.commercial_setoff_admission.admissions, {ch, id}),
      do: {:error, :commercial_setoff_admission_conflict},
      else: :ok
  end

  defp evidence_subject?(p, gate, ch) do
    case p["kind"] do
      "corporate_grant" -> Map.has_key?(gate.members, {ch, p["subject_id"]})
      "non_prohibition" -> p["subject_id"] == ch
      _ -> false
    end
  end

  defp registered_signer(%Envelope{chapter_id: ch, signers: [s]}, gate, role) do
    if s.role == role and get_in(gate.role_keys, [{ch, role}, s.key_id]) == s.pubkey,
      do: :ok,
      else: {:error, :unregistered_commercial_review_signer}
  end

  defp registered_signer(_, _, _), do: {:error, :unregistered_commercial_review_signer}

  defp current_parties(%Envelope{chapter_id: ch, payload: p, signers: signers}, gate) do
    expected =
      for role <- ~w(party_a party_b),
          %{key_id: key_id, pubkey: pubkey} <- [gate.members[{ch, p[role]}]],
          do: %{role: role, key_id: key_id, pubkey: pubkey}

    with [a, b] <- expected,
         true <- a.pubkey != b.pubkey and Enum.sort(expected) == Enum.sort(signers) do
      :ok
    else
      _ -> {:error, :invalid_commercial_participant_consent}
    end
  end

  defp current_evidence(
         %Envelope{chapter_id: ch, payload: p, signers: parties},
         gate,
         digest,
         now
       ) do
    required = [
      {p["grant_a_id"], "corporate_grant", p["party_a"]},
      {p["grant_b_id"], "corporate_grant", p["party_b"]},
      {p["non_prohibition_id"], "non_prohibition", ch}
    ]

    reviewers =
      for {id, kind, subject} <- required,
          %{active: true, envelope: evidence} <- [
            gate.commercial_setoff_admission.evidence[{ch, id}]
          ],
          ep = evidence.payload,
          ep["kind"] == kind and ep["subject_id"] == subject and ep["terms_digest"] == digest,
          ep["not_before_ms"] <= now and now < ep["expires_at_ms"],
          registered_signer(evidence, gate, @reviewer) == :ok,
          do: hd(evidence.signers)

    keys = Enum.map(parties ++ reviewers, & &1.pubkey)

    if length(reviewers) == 3 and length(Enum.uniq(keys)) == 5,
      do: :ok,
      else: {:error, :commercial_review_evidence_unavailable}
  end

  # Live checks only. Replay folds old netting/discharge records as written.
  def check_existing_rail(%Envelope{type: "NettingExecuted", chapter_id: ch}, gate) do
    if protected?(gate, ch),
      do: {:error, :legacy_netting_disabled_in_commercial_review},
      else: :ok
  end

  def check_existing_rail(%Envelope{type: type, chapter_id: ch, payload: p}, gate)
      when type in ["ObligationAssigned", "ObligationDischarged"] do
    id = p["obligation_id"]
    if reserved?(gate, ch, id), do: {:error, {:commercial_source_reserved, id}}, else: :ok
  end

  def check_existing_rail(_, _), do: :ok

  def protected?(gate, ch), do: MapSet.member?(gate.commercial_setoff_admission.profiles, ch)
  def reserved?(gate, ch, id), do: Map.has_key?(gate.commercial_setoff_admission.claims, {ch, id})

  def fold(%Envelope{type: @profile, chapter_id: ch}, state) do
    update_in(state.commercial_setoff_admission.profiles, &MapSet.put(&1, ch))
  end

  def fold(%Envelope{type: @evidence, chapter_id: ch, event_id: id} = env, state) do
    put_in(state.commercial_setoff_admission.evidence[{ch, id}], %{envelope: env, active: true})
  end

  def fold(%Envelope{type: @revoke, chapter_id: ch, payload: p}, state) do
    put_in(state.commercial_setoff_admission.evidence[{ch, p["evidence_id"]}].active, false)
  end

  def fold(%Envelope{type: @admit, chapter_id: ch, payload: p} = env, state) do
    key = {ch, p["intent_id"]}

    state
    |> put_in([:commercial_setoff_admission, :admissions, key], env)
    |> update_in([:commercial_setoff_admission, :claims], fn claims ->
      Enum.reduce(p["sources"], claims, &Map.put(&2, {ch, &1["obligation_id"]}, key))
    end)
  end

  def revoke_reviewer(state, chapter, key_id) do
    update_in(state.commercial_setoff_admission.evidence, fn evidence ->
      Map.new(evidence, fn
        {{^chapter, _} = key, %{envelope: %{signers: [%{key_id: ^key_id}]}} = row} ->
          {key, %{row | active: false}}

        entry ->
          entry
      end)
    end)
  end

  # An exact signed retry recovers a prior receipt. The original commit is the
  # sole authorization point; a recovered receipt cannot create a new claim.
  def duplicate([%Envelope{type: @admit, chapter_id: ch, payload: p} = env], gate) do
    case gate.commercial_setoff_admission.admissions[{ch, p["intent_id"]}] do
      nil ->
        :new

      accepted ->
        if Envelope.signed_core_term(env) === Envelope.signed_core_term(accepted) and
             env.sigs === accepted.sigs,
           do: {:ok, [accepted]},
           else: {:error, :commercial_setoff_admission_conflict}
    end
  end

  def duplicate(envelopes, _gate) do
    if Enum.any?(envelopes, &(&1.type == @admit)),
      do: {:error, :commercial_setoff_admission_requires_singleton},
      else: :new
  end
end
