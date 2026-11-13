defmodule CoopSubstrate.CommercialSetoffAdmissionTest do
  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.CommercialSetoffAdmission, as: Admission
  alias CoopSubstrate.Log
  alias CoopSubstrate.Projections.Membership

  @chapter "chapter-genesis"
  @admit "CommercialSetoffAdmittedV2"
  @profile "CommercialSetoffReviewProfileEnabledV2"
  @reviewer "commercial_setoff_reviewer"

  setup do
    governance = new_member("governance")
    declare(governance, governance)
    reviewers = for _ <- 1..3, do: new_member(@reviewer)
    Enum.each(reviewers, &declare(governance, &1))

    parties =
      Map.new(~w(A B C), fn id ->
        member = new_member("member")
        append!(signed_event(member, "MemberRegistered", registration_payload(id, member)))
        {id, member}
      end)

    %{governance: governance, reviewers: reviewers, parties: parties}
  end

  test "same-total substitution and changed signed core or revision are refused", ctx do
    enable(ctx)
    sources(ctx)
    {terms, refs} = reviewed(ctx, "original")

    for key <- ~w(revision signed_core_digest) do
      [first | rest] = terms["sources"]
      changed = %{terms | "sources" => [Map.put(first, key, 2) | rest]}
      assert reject(admission(ctx, changed, refs)) == :commercial_setoff_terms_mismatch
    end

    append!(discharge(ctx, "ob-a"))
    append!(obligation(ctx, "ob-substitute", "A", "B", 100))
    assert reject(admission(ctx, terms, refs)) == :commercial_setoff_terms_mismatch
    assert Log.gate().commercial_setoff_admission.claims == %{}
  end

  test "assignment out and back invalidates the cited original across restart", ctx do
    enable(ctx)
    sources(ctx)
    {terms, refs} = reviewed(ctx, "reassigned")

    append!(assignment(ctx, "A", "C"))
    append!(assignment(ctx, "C", "A"))
    restart_log()
    assert Log.gate().obligations[{@chapter, "ob-a"}].debtor_id == "A"
    assert reject(admission(ctx, terms, refs)) == {:ineligible_commercial_source, "ob-a"}
  end

  test "grant revocation and expiry refuse a new append even with signed consent", ctx do
    enable(ctx)
    sources(ctx)
    {terms, refs} = reviewed(ctx, "revoked")
    event = admission(ctx, terms, refs)

    revoke =
      signed_event(ctx.governance, "CommercialSetoffReviewEvidenceRevokedV2", %{
        "evidence_id" => refs["grant_a_id"]
      })

    append!(revoke)
    restart_log()
    assert reject(event) == :commercial_review_evidence_unavailable

    {terms, refs} = reviewed(ctx, "expires")
    event = admission(ctx, terms, refs)
    gate = Log.gate()

    expires =
      gate.commercial_setoff_admission.evidence[{@chapter, refs["grant_a_id"]}].envelope.payload[
        "expires_at_ms"
      ]

    assert Admission.check(event, gate, expires) ==
             {:error, :commercial_review_evidence_unavailable}
  end

  test "redeclaration of a reviewer key does not revive its old grants", ctx do
    enable(ctx)
    sources(ctx)
    {terms, refs} = reviewed(ctx, "reviewer-revoked")
    [reviewer | _] = ctx.reviewers

    append!(
      signed_event(ctx.governance, "RoleKeyRevoked", %{
        "role" => @reviewer,
        "key_id" => reviewer.signer.key_id
      })
    )

    declare(ctx.governance, reviewer)
    restart_log()
    assert reject(admission(ctx, terms, refs)) == :commercial_review_evidence_unavailable
  end

  test "key rotation invalidates the old consent and terms approval, including rotation back",
       ctx do
    enable(ctx)
    sources(ctx)
    {terms, refs} = reviewed(ctx, "rotated")
    original = admission(ctx, terms, refs)
    replacement = new_member("member")

    append!(rotation(ctx.parties["A"], replacement))
    assert reject(original) == :invalid_commercial_participant_consent
    append!(rotation(replacement, ctx.parties["A"]))
    assert reject(original) == :commercial_review_evidence_unavailable
  end

  test "participant-controlled and reused reviewer keys cannot authorize admission", ctx do
    enable(ctx)
    sources(ctx)
    participant = role(ctx.parties["A"], @reviewer)
    declare(ctx.governance, participant)
    [first, second, third] = ctx.reviewers

    for reviewers <- [[participant, second, third], [first, first, third]] do
      {terms, refs} = reviewed(%{ctx | reviewers: reviewers}, "not-independent")
      assert reject(admission(ctx, terms, refs)) == :commercial_review_evidence_unavailable
    end
  end

  test "missing review profile and fabricated evidence IDs cannot authorize a claim", ctx do
    sources(ctx)
    {:ok, terms} = Admission.terms(Log.gate(), @chapter, {"A", "B"}, "USD", "missing")

    refs = %{
      "grant_a_id" => "fake-a",
      "grant_b_id" => "fake-b",
      "non_prohibition_id" => "fake-law"
    }

    event = admission(ctx, terms, refs)

    assert reject(event) == :commercial_review_profile_required
    enable(ctx)
    assert reject(event) == :commercial_review_evidence_unavailable
  end

  test "one concurrent claim commits, exact retry recovers it, and sources stay open", ctx do
    enable(ctx)
    sources(ctx)
    first = reviewed_event(ctx, "claim-1")
    second = reviewed_event(ctx, "claim-2")
    head = Log.head()

    calls =
      for event <- [first, second] do
        Task.async(fn ->
          receive do
            :append -> {event, Log.append(event)}
          end
        end)
      end

    Enum.each(calls, &send(&1.pid, :append))
    results = Enum.map(calls, &Task.await(&1))
    [{winner, {:ok, [receipt]}}] = Enum.filter(results, &match?({_, {:ok, _}}, &1))

    [{loser, {:error, {:reject, 0, {:commercial_source_reserved, _}}}}] =
      Enum.filter(results, &match?({_, {:error, _}}, &1))

    assert Log.head().global_seq == head.global_seq + 1
    restart_log()
    assert {:ok, [^receipt]} = Log.append(winner)
    assert Log.head().global_seq == head.global_seq + 1
    assert {:commercial_source_reserved, _} = reject(loser)

    assert Log.append(admission(ctx, winner.payload, %{})) ==
             {:error, :commercial_setoff_admission_conflict}

    assert reject(discharge(ctx, "ob-a")) == {:commercial_source_reserved, "ob-a"}
    assert reject(assignment(ctx, "A", "C")) == {:commercial_source_reserved, "ob-a"}
    assert Log.gate().obligations[{@chapter, "ob-a"}].open
    assert Log.gate().obligations[{@chapter, "ob-b"}].open
    assert map_size(Log.gate().commercial_setoff_admission.claims) == 2
    assert {:ok, replayed} = Log.replay(Membership)
    assert replayed.commercial_setoff_admission == Log.gate().commercial_setoff_admission
    assert :ok = Log.verify_chains()
  end

  test "a stale appender cannot commit a competing claim and can recover the winner", ctx do
    enable(ctx)
    sources(ctx)
    winner = reviewed_event(ctx, "cross-appender-winner")
    loser = reviewed_event(ctx, "cross-appender-loser")
    head = Log.head()
    {:ok, stale} = Log.start_link(name: :commercial_review_stale_appender)
    Process.unlink(stale)
    monitor = Process.monitor(stale)

    on_exit(fn -> if Process.alive?(stale), do: GenServer.stop(stale) end)

    receipt = append!(winner)
    assert {:error, {:store_append_failed, :wrong_expected_version}} = Log.append(loser, stale)
    assert_receive {:DOWN, ^monitor, :process, ^stale, :ledger_moved}, 2_000

    {:ok, recovered} = Log.start_link(name: :commercial_review_recovered_appender)
    Process.unlink(recovered)
    on_exit(fn -> if Process.alive?(recovered), do: GenServer.stop(recovered) end)

    assert {:ok, [^receipt]} = Log.append(winner, recovered)

    assert {:error, {:reject, 0, {:commercial_source_reserved, _}}} =
             Log.append(loser, recovered)

    assert Log.head(recovered).global_seq == head.global_seq + 1
    assert :ok = Log.verify_chains()
  end

  test "historical aggregate netting replays, while new aggregate netting is fenced", ctx do
    sources(ctx, "old")
    append!(netting(ctx, "historical-residual"))
    sources(ctx)
    profile = signed_event(ctx.governance, @profile, %{})
    head = Log.head()

    assert {:error, {:reject, 1, :legacy_netting_disabled_in_commercial_review}} =
             Log.append([profile, netting(ctx, "batch-residual")])

    assert Log.head() == head
    refute Admission.protected?(Log.gate(), @chapter)
    append!(profile)
    restart_log()

    assert Log.gate().obligations[{@chapter, "old-a"}].open == false
    assert Log.gate().obligations[{@chapter, "historical-residual"}].open
    assert reject(netting(ctx, "new-residual")) == :legacy_netting_disabled_in_commercial_review
    assert Log.gate().obligations[{@chapter, "ob-a"}].open
    assert :ok = Log.verify_chains()
  end

  defp reviewed_event(ctx, id) do
    {terms, refs} = reviewed(ctx, id)
    admission(ctx, terms, refs)
  end

  defp reviewed(ctx, id) do
    gate = Log.gate()
    {:ok, terms} = Admission.terms(gate, @chapter, {"A", "B"}, "USD", id)
    {:ok, digest} = Admission.terms_digest(gate, @chapter, terms)

    subjects = [
      {"grant_a_id", "corporate_grant", "A"},
      {"grant_b_id", "corporate_grant", "B"},
      {"non_prohibition_id", "non_prohibition", @chapter}
    ]

    refs =
      Map.new(Enum.zip(subjects, ctx.reviewers), fn {{field, kind, subject}, reviewer} ->
        event =
          signed_event(reviewer, "CommercialSetoffReviewEvidenceRecordedV2", %{
            "kind" => kind,
            "subject_id" => subject,
            "terms_digest" => digest,
            "record_digest" => {:bytes, :crypto.hash(:sha256, subject)},
            "not_before_ms" => 0,
            "expires_at_ms" => System.system_time(:millisecond) + 300_000
          })

        {field, append!(event).event_id}
      end)

    {terms, refs}
  end

  defp admission(ctx, terms, refs) do
    multi_signed_event(
      [role(ctx.parties["A"], "party_a"), role(ctx.parties["B"], "party_b")],
      @admit,
      Map.merge(terms, refs)
    )
  end

  defp declare(governance, actor) do
    append!(
      signed_event(governance, "RoleKeyDeclared", %{
        "role" => actor.signer.role,
        "key_id" => actor.signer.key_id,
        "pubkey" => {:bytes, actor.signer.pubkey}
      })
    )
  end

  defp enable(ctx), do: append!(signed_event(ctx.governance, @profile, %{}))

  defp sources(ctx, prefix \\ "ob") do
    append!(obligation(ctx, prefix <> "-a", "A", "B", 100))
    append!(obligation(ctx, prefix <> "-b", "B", "A", 60))
  end

  defp obligation(ctx, id, debtor, creditor, amount) do
    multi_signed_event(
      [role(ctx.parties[debtor], "debtor"), role(ctx.parties[creditor], "creditor")],
      "ObligationRecorded",
      %{
        "obligation_id" => id,
        "debtor_id" => debtor,
        "creditor_id" => creditor,
        "amount_minor" => amount,
        "denomination" => "USD"
      }
    )
  end

  defp discharge(ctx, id) do
    multi_signed_event(
      [role(ctx.parties["A"], "debtor"), role(ctx.parties["B"], "creditor")],
      "ObligationDischarged",
      %{"obligation_id" => id}
    )
  end

  defp assignment(ctx, from, to) do
    multi_signed_event(
      [role(ctx.parties[from], "assignor"), role(ctx.parties[to], "assignee")],
      "ObligationAssigned",
      %{"obligation_id" => "ob-a", "new_debtor_id" => to}
    )
  end

  defp rotation(old, new) do
    signed_event(role(old, "author"), "KeyRotated", %{
      "member_id" => "A",
      "old_key_id" => old.signer.key_id,
      "new_key_id" => new.signer.key_id,
      "new_pubkey" => {:bytes, new.signer.pubkey}
    })
  end

  defp netting(ctx, residual_id) do
    multi_signed_event(
      [role(ctx.parties["A"], "party_a"), role(ctx.parties["B"], "party_b")],
      "NettingExecuted",
      %{
        "party_a" => "A",
        "party_b" => "B",
        "denomination" => "USD",
        "a_to_b" => 100,
        "b_to_a" => 60,
        "setoff" => 60,
        "residual_obligation_id" => residual_id,
        "net_debtor" => "A",
        "net_creditor" => "B",
        "net_minor" => 40
      }
    )
  end

  defp role(actor, name), do: %{actor | signer: %{actor.signer | role: name}}

  defp append!(event) do
    assert {:ok, [receipt]} = Log.append(event)
    receipt
  end

  defp reject(event) do
    assert {:error, {:reject, 0, reason}} = Log.append(event)
    reason
  end
end
