defmodule CoopSubstrate.CrossCurrencyProvenanceTest do
  @moduledoc """
  Synthetic businesses through the actual PostgreSQL-backed signed log.
  Detached corporate attestations use a fixture-only steward policy; they
  are not real mandates, PR #392 admissions, or legal determinations.
  """
  use CoopSubstrate.LogCase, async: false

  alias BarterCore.{CrossCurrencyConsent, CrossCurrencySetoff}
  alias CoopSubstrate.{Canonical, Crypto, Log}
  alias CoopSubstrate.CrossCurrencyProvenanceFixture, as: Fixture
  alias CoopSubstrate.Protocol.Envelope

  @chapter "chapter-genesis"
  @now 1_800_000_000_000
  @expiry @now + 60_000
  @alice "https://fixture.example/businesses/alice"
  @bob "https://fixture.example/businesses/bob"
  @carol "https://fixture.example/businesses/carol"
  @usd "https://fixture.example/obligations/usd"
  @eur "https://fixture.example/obligations/eur"
  @intent "https://fixture.example/consents/fx"

  setup do
    gov = new_member("governance")
    reviewers = [new_member("steward"), new_member("steward")]
    alice = new_member("member")
    bob = new_member("member")
    carol = new_member("member")

    declare!(gov, gov, "governance")
    Enum.each(reviewers, &declare!(gov, &1, "steward"))

    for {id, actor} <- [{@alice, alice}, {@bob, bob}, {@carol, carol}] do
      {:ok, [_]} =
        Log.append(signed_event(actor, "MemberRegistered", registration_payload(id, actor)))
    end

    ab = record!(alice, bob, @usd, @alice, @bob, 120, "USD")
    ba = record!(bob, alice, @eur, @bob, @alice, 75, "EUR")

    rate = %{
      base_currency: "EUR",
      quote_currency: "USD",
      numerator: 3,
      denominator: 2,
      agreed_at: @now - 1,
      valid_until: @expiry,
      agreement_ref: "fixture://negotiated-terms",
      evidence_ref: "fixture://rate-evidence"
    }

    {:ok, plan} =
      CrossCurrencySetoff.propose(source(ab), source(ba), rate, @intent, @now)

    opts = [trusted_governance: Map.take(gov.signer, [:key_id, :pubkey])]
    {:ok, proof, snapshot} = Fixture.prepare(plan, @chapter, @now, opts)

    ctx = %{
      gov: gov,
      reviewers: reviewers,
      alice: alice,
      bob: bob,
      carol: carol,
      originals: [ab, ba],
      plan: plan,
      proof: proof,
      snapshot: snapshot,
      opts: opts
    }

    Map.merge(ctx, %{signatures: sign(ctx, proof), grants: grants(ctx, proof)})
  end

  test "independently derives exact signed sources and current keys without changing the log",
       ctx do
    assert {:ok, receipt} = verify(ctx)
    assert receipt.status == :inert_cryptographic_consents_only
    assert receipt.source_authentication == :external_not_verified
    assert receipt.agency_authority == :external_not_verified
    assert receipt.admission == :not_authorized
    assert receipt.contractual_discharge == :not_established
    assert receipt.currency_exchange == :none
    assert receipt.financial_settlement == :none

    assert receipt.fixture_evidence.evidence_class ==
             :synthetic_fixture_using_signed_local_history

    assert receipt.fixture_evidence.actual_corporate_authority == :unverified
    assert receipt.fixture_evidence.real_world_invoice_validity == :unverified
    assert receipt.fixture_evidence.legal_classification == :undetermined
    assert receipt.discharge == :not_executed
    assert receipt.accounting_posting == :none
    assert receipt.source_reservation == :none

    for event <- ctx.originals do
      id = event.payload["obligation_id"]
      {:ok, full_hash} = Envelope.event_hash(event)
      {:ok, core} = Envelope.signing_bytes(event)
      assert ctx.snapshot.source_hashes[id] == full_hash
      refute full_hash == :crypto.hash(:sha256, core)
      assert Log.gate().obligations[{@chapter, id}].open
      assert Log.gate().obligations[{@chapter, id}].amount_minor == event.payload["amount_minor"]
    end

    assert ctx.snapshot.members[@alice] == Map.take(ctx.alice.signer, [:key_id, :pubkey])
    assert ctx.snapshot.members[@bob] == Map.take(ctx.bob.signer, [:key_id, :pubkey])
    assert Log.gate().commercial_admission.reservations == %{}
    assert Log.gate().commercial_admission.intents == %{}
  end

  test "a fabricated digest can satisfy pure consent but cannot satisfy source provenance", ctx do
    fabricated =
      Map.put(ctx.snapshot.source_hashes, @usd, :crypto.hash(:sha256, "not-an-event"))

    {:ok, proof} =
      CrossCurrencyConsent.prepare(ctx.plan, @chapter, fabricated, ctx.snapshot.members, @now)

    signatures = sign(ctx, proof)

    assert {:ok, _} =
             CrossCurrencyConsent.verify(
               proof,
               ctx.plan,
               @chapter,
               fabricated,
               ctx.snapshot.members,
               signatures,
               @now
             )

    assert {:error, _} =
             verify(ctx, proof: proof, signatures: signatures, grants: grants(ctx, proof))
  end

  test "re-signed invented amount, denomination, ID and revision cannot replace signed source facts",
       ctx do
    for change <- [
          %{amount_minor: 121},
          %{id: "https://fixture.example/obligations/invented"},
          %{revision: 2},
          %{currency: "GBP"}
        ] do
      a = Map.merge(ctx.plan.a_to_b, change)
      rate = %{ctx.plan.rate | quote_currency: a.currency}
      {:ok, plan} = CrossCurrencySetoff.propose(a, ctx.plan.b_to_a, rate, @intent, @now)
      hashes = Map.new([a, plan.b_to_a], &{&1.id, :crypto.hash(:sha256, &1.id)})

      {:ok, proof} =
        CrossCurrencyConsent.prepare(plan, @chapter, hashes, ctx.snapshot.members, @now)

      signatures = sign(ctx, proof)

      assert {:ok, _} =
               CrossCurrencyConsent.verify(
                 proof,
                 plan,
                 @chapter,
                 hashes,
                 ctx.snapshot.members,
                 signatures,
                 @now
               )

      assert {:error, _} =
               verify(ctx,
                 plan: plan,
                 proof: proof,
                 signatures: signatures,
                 grants: grants(ctx, proof)
               )
    end
  end

  test "assignment away and back cannot revive an original revision", ctx do
    assign!(ctx.alice, ctx.carol, @carol)
    assign!(ctx.carol, ctx.alice, @alice)
    assert Log.gate().obligations[{@chapter, @usd}].debtor_id == @alice
    assert Log.gate().commercial_source_lineage[{@chapter, @usd}].source_revision == 3
    assert {:error, _} = verify(ctx)
    assert :ok = Log.verify_chains()
  end

  test "real role revocation defeats a still-valid detached grant signature", ctx do
    [reviewer | _] = ctx.reviewers
    revoke!(ctx.gov, reviewer)
    assert {:error, _} = verify(ctx)
    assert :ok = Log.verify_chains()
  end

  test "redeclaring the same issuer key does not resurrect the old grant", ctx do
    [reviewer | _] = ctx.reviewers
    revoke!(ctx.gov, reviewer)
    declare!(ctx.gov, reviewer, "steward")

    assert get_in(Log.gate().role_keys, [{@chapter, "steward"}, reviewer.signer.key_id]) ==
             reviewer.signer.pubkey

    assert {:error, _} = verify(ctx)
  end

  test "current member key rotation rejects old consent and old grant", ctx do
    rotated = new_member("member")
    rotate!(ctx.alice, rotated)
    assert {:error, _} = verify(ctx)

    {:ok, proof, snapshot} = Fixture.prepare(ctx.plan, @chapter, @now, ctx.opts)
    fresh = %{ctx | alice: rotated, proof: proof, snapshot: snapshot}
    signatures = sign(fresh, proof)
    assert {:error, _} = verify(fresh, signatures: signatures)
    assert {:ok, _} = verify(fresh, signatures: signatures, grants: grants(fresh, proof))
  end

  test "rotating away and back requires renewed grant evidence even when pure consent verifies",
       ctx do
    rotated = new_member("member")
    rotate!(ctx.alice, rotated)
    rotate!(rotated, ctx.alice)
    {:ok, snapshot} = Fixture.snapshot(ctx.plan, @chapter, @now, ctx.opts)
    assert snapshot.members == ctx.snapshot.members
    assert snapshot.member_revisions[@alice] > ctx.snapshot.member_revisions[@alice]

    assert {:ok, _} =
             CrossCurrencyConsent.verify(
               ctx.proof,
               ctx.plan,
               @chapter,
               snapshot.source_hashes,
               snapshot.members,
               ctx.signatures,
               @now
             )

    assert {:error, _} = verify(ctx)
  end

  test "changed negotiated terms require new party signatures and new scoped grants", ctx do
    rate = %{
      ctx.plan.rate
      | numerator: 5,
        denominator: 4,
        agreement_ref: "fixture://amended-terms"
    }

    {:ok, plan} =
      CrossCurrencySetoff.propose(ctx.plan.a_to_b, ctx.plan.b_to_a, rate, @intent, @now)

    assert {:error, _} = verify(ctx, plan: plan)

    {:ok, proof, snapshot} = Fixture.prepare(plan, @chapter, @now, ctx.opts)
    fresh = %{ctx | plan: plan, proof: proof, snapshot: snapshot}
    signatures = sign(fresh, proof)
    assert {:error, _} = verify(fresh, signatures: signatures)
    assert {:ok, _} = verify(fresh, signatures: signatures, grants: grants(fresh, proof))
  end

  test "missing, tampered and wrong-subject grant evidence fails closed", ctx do
    for invalid <- [
          %{},
          Map.delete(ctx.grants, @alice),
          put_in(ctx.grants, [@alice, :signature], <<0::512>>),
          Map.put(ctx.grants, @alice, ctx.grants[@bob]),
          Map.put(ctx.grants, "B-extra", ctx.grants[@bob]),
          put_in(ctx.grants, [@alice, :body, "unexpected"], true)
        ] do
      assert {:error, _} = verify(ctx, grants: invalid)
    end
  end

  test "one reviewer cannot provide both independent fixture attestations", ctx do
    [reviewer | _] = ctx.reviewers

    {:ok, grant_b} =
      Fixture.issue_grant(ctx.snapshot, ctx.proof, @bob, reviewer, @now, @expiry)

    assert {:error, _} = verify(ctx, grants: Map.put(ctx.grants, @bob, grant_b))
  end

  test "grant validity uses the verification clock with exclusive expiry", ctx do
    [reviewer | _] = ctx.reviewers

    {:ok, expiring} =
      Fixture.issue_grant(ctx.snapshot, ctx.proof, @alice, reviewer, @now, @now + 10)

    assert {:ok, _} = verify(ctx, grants: Map.put(ctx.grants, @alice, expiring), now: @now + 9)

    assert {:error, _} =
             verify(ctx, grants: Map.put(ctx.grants, @alice, expiring), now: @now + 10)

    {:ok, future} =
      Fixture.issue_grant(ctx.snapshot, ctx.proof, @alice, reviewer, @now + 10, @expiry)

    assert {:error, _} = verify(ctx, grants: Map.put(ctx.grants, @alice, future))
  end

  test "trusted governance comes from fixture configuration, never from the proof", ctx do
    impostor = new_member("governance")
    wrong = [trusted_governance: Map.take(impostor.signer, [:key_id, :pubkey])]
    assert {:error, _} = verify(ctx, opts: wrong)
    assert {:error, _} = verify(ctx, opts: [])
  end

  test "malformed inputs refuse without raising or changing any ledger state", ctx do
    for invalid <- [
          [proof: nil],
          [plan: %{}],
          [plan: nil],
          [signatures: []],
          [grants: nil],
          [now: -1],
          [opts: %{trusted_governance: ctx.gov.signer}],
          [opts: ctx.opts ++ ctx.opts]
        ] do
      assert {:error, _} = verify(ctx, invalid)
    end
  end

  test "stored signature tampering is refused before consent; restoring bytes restores acceptance",
       ctx do
    [event | _] = ctx.originals
    {:ok, original} = Canonical.encode(Envelope.full_record_term(event))
    signer = hd(event.signers)
    forged = %{event | sigs: Map.put(event.sigs, signer.key_id, <<0::512>>)}
    {:ok, bytes} = Canonical.encode(Envelope.full_record_term(forged))

    try do
      replace_record!(event.global_seq, bytes)
      assert {:error, _} = Log.verify_chains()
      assert {:error, _} = verify(ctx)
    after
      replace_record!(event.global_seq, original)
    end

    assert {:ok, _} = verify(ctx)
  end

  test "unsigned log placement is covered by chain authentication as well as author signatures",
       ctx do
    [event | _] = ctx.originals
    {:ok, original} = Canonical.encode(Envelope.full_record_term(event))
    forged = %{event | stream_seq: event.stream_seq + 1}
    assert :ok = Envelope.verify(forged)
    {:ok, bytes} = Canonical.encode(Envelope.full_record_term(forged))

    try do
      replace_record!(event.global_seq, bytes)
      assert {:error, _} = verify(ctx)
    after
      replace_record!(event.global_seq, original)
    end
  end

  test "a concurrent append between capture and final validation refuses the snapshot", ctx do
    append = fn ->
      actor = new_member("member")

      {:ok, [_]} =
        Log.append(
          signed_event(actor, "MemberRegistered", registration_payload("B-racing", actor))
        )
    end

    opts = Keyword.put(ctx.opts, :after_capture, append)

    assert {:error, :concurrent_ledger_change} =
             Fixture.verify(ctx.proof, ctx.plan, @chapter, ctx.signatures, ctx.grants, @now, opts)
  end

  test "fresh restart reconstructs the same source hashes, key epochs and verification", ctx do
    before = Log.head()
    restart_log()
    {:ok, snapshot} = Fixture.snapshot(ctx.plan, @chapter, @now, ctx.opts)
    assert snapshot.source_hashes == ctx.snapshot.source_hashes
    assert snapshot.member_revisions == ctx.snapshot.member_revisions
    assert snapshot.observed_head == before
    assert {:ok, _} = verify(ctx)
  end

  test "fixture refuses history outside its explicitly reviewed event vocabulary", ctx do
    {:ok, [_]} = Log.append(signed_test_event(new_member()))
    assert {:error, _} = verify(ctx)
  end

  test "64-event boundary succeeds and the next authentic append exceeds the fixture bound",
       ctx do
    for n <- (Log.head().global_seq + 1)..64 do
      actor = new_member("member")

      {:ok, [_]} =
        Log.append(
          signed_event(actor, "MemberRegistered", registration_payload("B-extra-#{n}", actor))
        )
    end

    assert Log.head().global_seq == 64
    assert {:ok, _} = verify(ctx)
    actor = new_member("member")

    {:ok, [_]} =
      Log.append(
        signed_event(actor, "MemberRegistered", registration_payload("B-over-limit", actor))
      )

    assert {:error, :fixture_history_limit_exceeded} = verify(ctx)
  end

  defp verify(ctx, overrides \\ []) do
    before_head = Log.head()
    before_gate = Log.gate()

    result =
      Fixture.verify(
        Keyword.get(overrides, :proof, ctx.proof),
        Keyword.get(overrides, :plan, ctx.plan),
        @chapter,
        Keyword.get(overrides, :signatures, ctx.signatures),
        Keyword.get(overrides, :grants, ctx.grants),
        Keyword.get(overrides, :now, @now),
        Keyword.get(overrides, :opts, ctx.opts)
      )

    assert Log.head() == before_head
    assert Log.gate() == before_gate
    result
  end

  defp sign(ctx, proof) do
    Map.new([{@alice, ctx.alice}, {@bob, ctx.bob}], fn {id, actor} ->
      {id,
       %{key_id: actor.signer.key_id, signature: Crypto.sign(proof.signing_bytes, actor.seed)}}
    end)
  end

  defp grants(ctx, proof) do
    [a, b] = ctx.reviewers

    Map.new([{@alice, a}, {@bob, b}], fn {principal, issuer} ->
      {:ok, grant} = Fixture.issue_grant(ctx.snapshot, proof, principal, issuer, @now, @expiry)
      {principal, grant}
    end)
  end

  defp role(actor, name), do: %{actor | signer: %{actor.signer | role: name}}

  defp declare!(gov, actor, role) do
    {:ok, [_]} =
      Log.append(
        signed_event(gov, "RoleKeyDeclared", %{
          "role" => role,
          "key_id" => actor.signer.key_id,
          "pubkey" => {:bytes, actor.signer.pubkey}
        })
      )
  end

  defp revoke!(gov, actor) do
    {:ok, [_]} =
      Log.append(
        signed_event(gov, "RoleKeyRevoked", %{
          "role" => "steward",
          "key_id" => actor.signer.key_id
        })
      )
  end

  defp rotate!(old, new) do
    {:ok, [_]} =
      Log.append(
        signed_event(role(old, "author"), "KeyRotated", %{
          "member_id" => @alice,
          "old_key_id" => old.signer.key_id,
          "new_key_id" => new.signer.key_id,
          "new_pubkey" => {:bytes, new.signer.pubkey}
        })
      )
  end

  defp assign!(old, new, new_id) do
    {:ok, [_]} =
      Log.append(
        multi_signed_event(
          [role(old, "assignor"), role(new, "assignee")],
          "ObligationAssigned",
          %{"obligation_id" => @usd, "new_debtor_id" => new_id}
        )
      )
  end

  defp record!(debtor, creditor, id, d, c, amount, currency) do
    {:ok, [event]} =
      Log.append(
        multi_signed_event(
          [role(debtor, "debtor"), role(creditor, "creditor")],
          "ObligationRecorded",
          %{
            "obligation_id" => id,
            "debtor_id" => d,
            "creditor_id" => c,
            "amount_minor" => amount,
            "denomination" => currency
          }
        )
      )

    event
  end

  defp source(event) do
    p = event.payload

    %{
      id: p["obligation_id"],
      debtor: p["debtor_id"],
      creditor: p["creditor_id"],
      currency: p["denomination"],
      amount_minor: p["amount_minor"],
      revision: event.stream_seq,
      evidence_ref: "fixture://invoice/" <> p["obligation_id"],
      valid_until: @expiry,
      status: :host_declared_eligible
    }
  end

  defp replace_record!(seq, bytes) do
    with_update_bypass(fn conn ->
      %{num_rows: 1} =
        Postgrex.query!(
          conn,
          "UPDATE events SET data=$1 WHERE event_id IN " <>
            "(SELECT event_id FROM stream_events WHERE stream_id=" <>
            "(SELECT stream_id FROM streams WHERE stream_uuid='ledger') AND stream_version=$2)",
          [bytes, seq]
        )
    end)
  end
end
