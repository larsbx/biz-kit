defmodule CoopSubstrate.CommercialSetoffProofTest do
  @moduledoc """
  Cryptographic negative tests for an INERT contract. Test-only agency,
  source-revision and legal-reference data do not establish actual authority,
  source provenance, legal setoff or release.
  """
  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.CommercialSetoffProof, as: Proof
  alias CoopSubstrate.Crypto
  alias CoopSubstrate.Log
  alias CoopSubstrate.Protocol.Envelope

  @chapter "chapter-genesis"

  defp as_role(actor, role), do: %{actor | signer: %{actor.signer | role: role}}

  defp record!(debtor, creditor, id, debtor_id, creditor_id, amount, currency \\ "USD") do
    {:ok, [event]} =
      Log.append(
        multi_signed_event(
          [as_role(debtor, "debtor"), as_role(creditor, "creditor")],
          "ObligationRecorded",
          %{
            "obligation_id" => id,
            "debtor_id" => debtor_id,
            "creditor_id" => creditor_id,
            "amount_minor" => amount,
            "denomination" => currency
          }
        )
      )

    event
  end

  defp source_from(event) do
    id = event.payload["obligation_id"]
    ob = Log.gate().obligations[{@chapter, id}]
    {:ok, digest} = Envelope.event_hash(event)

    %{
      "obligation_id" => id,
      "revision" => event.stream_seq,
      "source_event_hash" => digest,
      "debtor_id" => ob.debtor_id,
      "creditor_id" => ob.creditor_id,
      "amount_minor" => ob.amount_minor,
      "denomination" => ob.denomination
    }
  end

  defp grant(id, actor) do
    %{
      key_id: actor.signer.key_id,
      digest: :crypto.hash(:sha256, "synthetic-agency:" <> id),
      active: true
    }
  end

  defp refs do
    %{
      "jurisdiction" => "TEST-ONLY",
      "legal_basis_digest" => :crypto.hash(:sha256, "not-a-legal-contract"),
      "discharge_evidence_digest" => :crypto.hash(:sha256, "not-a-release"),
      "policy_decision_digest" => :crypto.hash(:sha256, "not-a-counsel-review")
    }
  end

  defp prepare(ctx, sources \\ nil, grants \\ nil, intent \\ "SET-1", evidence \\ nil) do
    Proof.prepare(
      Log.gate(),
      @chapter,
      {"M-alice", "M-bob"},
      "USD",
      sources || ctx.sources,
      intent,
      grants || ctx.grants,
      evidence || ctx.evidence
    )
  end

  defp sign(proof, ctx) do
    %{
      "M-alice" => %{
        key_id: ctx.alice.signer.key_id,
        signature: Crypto.sign(proof.signing_bytes, ctx.alice.seed)
      },
      "M-bob" => %{
        key_id: ctx.bob.signer.key_id,
        signature: Crypto.sign(proof.signing_bytes, ctx.bob.seed)
      }
    }
  end

  defp verify(ctx, overrides \\ []) do
    Proof.verify(
      Keyword.get(overrides, :proof, ctx.proof),
      Log.gate(),
      Keyword.get(overrides, :sources, ctx.sources),
      Keyword.get(overrides, :grants, ctx.grants),
      Keyword.get(overrides, :signatures, ctx.signatures),
      Keyword.get(overrides, :spent, MapSet.new())
    )
  end

  setup do
    alice = new_member("member")
    bob = new_member("member")

    for {id, actor} <- [{"M-alice", alice}, {"M-bob", bob}] do
      {:ok, [_]} =
        Log.append(signed_event(actor, "MemberRegistered", registration_payload(id, actor)))
    end

    one = record!(alice, bob, "OB-1", "M-alice", "M-bob", 100)
    two = record!(bob, alice, "OB-2", "M-bob", "M-alice", 60)

    grants = %{"M-alice" => grant("M-alice", alice), "M-bob" => grant("M-bob", bob)}
    sources = [source_from(one), source_from(two)]
    evidence = refs()

    ctx = %{alice: alice, bob: bob, grants: grants, sources: sources, evidence: evidence}
    {:ok, proof} = prepare(ctx)

    Map.merge(ctx, %{proof: proof, signatures: sign(proof, ctx)})
  end

  test "binds exact sorted source IDs, revisions, event digests, amounts, currency and keys", ctx do
    assert {:ok, result} = verify(ctx)
    assert result.status == :inert_cryptographic_checks_only
    assert result.admission == :not_authorized
    assert result.legally_effective_discharge == :not_verified
    assert result.financial_settlement == :none

    assert ctx.proof.body["setoff"] == 60
    assert Enum.map(ctx.proof.body["sources"], & &1["obligation_id"]) == ["OB-1", "OB-2"]
    assert length(ctx.proof.commitment) == 32
    assert ctx.proof.signed_event_binding == :none
    assert Log.gate().obligations[{@chapter, "OB-1"}].open

    assert {:ok, reordered} = prepare(ctx, Enum.reverse(ctx.sources))
    assert reordered.commitment == ctx.proof.commitment
    assert reordered.signing_bytes == ctx.proof.signing_bytes
  end

  test "rejects substituted original obligations even with unchanged aggregate balances", ctx do
    {:ok, [_]} =
      Log.append(
        multi_signed_event(
          [as_role(ctx.bob, "debtor"), as_role(ctx.alice, "creditor")],
          "ObligationDischarged",
          %{"obligation_id" => "OB-2"}
        )
      )

    replacement = record!(ctx.bob, ctx.alice, "OB-3", "M-bob", "M-alice", 60)
    current = [hd(ctx.sources), source_from(replacement)]

    assert {:error, :stale_or_substituted_source_binding} =
             verify(ctx, sources: current)

    assert {:error, :source_set_changed} = verify(ctx)
  end

  test "rejects a stale revision or source-event digest without changing net totals", ctx do
    [source | rest] = ctx.sources
    changed_rev = [%{source | "revision" => source["revision"] + 1} | rest]
    changed_hash = [%{source | "source_event_hash" => :crypto.hash(:sha256, "changed")} | rest]

    assert {:error, :stale_or_substituted_source_binding} = verify(ctx, sources: changed_rev)
    assert {:error, :stale_or_substituted_source_binding} = verify(ctx, sources: changed_hash)
    assert {:error, :cross_currency_source} =
             prepare(ctx, [%{source | "denomination" => "EUR"} | rest])
  end

  test "refuses missing, incorrect, or non-independent consent signatures", ctx do
    assert {:error, :two_independent_consents_required} =
             verify(ctx, signatures: Map.delete(ctx.signatures, "M-bob"))

    swapped = put_in(ctx.signatures, ["M-bob", :signature], ctx.signatures["M-alice"].signature)
    assert {:error, {:invalid_consent, "M-bob"}} = verify(ctx, signatures: swapped)

    invalid = put_in(ctx.signatures, ["M-alice", :key_id], "wrong-key")
    assert {:error, {:invalid_consent, "M-alice"}} = verify(ctx, signatures: invalid)
  end

  test "rejects a revoked agency reference and any changed independently supplied grant", ctx do
    revoked = put_in(ctx.grants, ["M-bob", :active], false)
    assert {:error, {:authority_inactive, "M-bob"}} = verify(ctx, grants: revoked)

    new_ref = put_in(ctx.grants, ["M-bob", :digest], :crypto.hash(:sha256, "new-agency"))
    assert {:error, :stale_or_substituted_source_binding} =
             verify(ctx, grants: new_ref)
  end

  test "rejects a rotated member key even though the old signature is valid Ed25519", ctx do
    replacement = new_member("member")

    {:ok, [_]} =
      Log.append(
        signed_event(as_role(ctx.bob, "author"), "KeyRotated", %{
          "member_id" => "M-bob",
          "old_key_id" => ctx.bob.signer.key_id,
          "new_key_id" => replacement.signer.key_id,
          "new_pubkey" => {:bytes, replacement.signer.pubkey}
        })
      )

    assert {:error, {:authority_key_stale, "M-bob"}} = verify(ctx)

    updated_grants = put_in(ctx.grants, ["M-bob", :key_id], replacement.signer.key_id)
    assert {:error, :stale_or_substituted_source_binding} =
             verify(ctx, grants: updated_grants)
  end

  test "detects model replay and real legacy-ledger discharge without claiming an atomic fence", ctx do
    assert {:error, :replayed_intent} =
             verify(ctx, spent: MapSet.new([ctx.proof.commitment]))

    assert {:error, :replayed_intent} =
             verify(ctx, spent: MapSet.new([{@chapter, "SET-1"}]))

    {:ok, env} =
      Envelope.new(
        chapter_id: @chapter,
        timestamp_ms: System.system_time(:millisecond),
        type: "NettingExecuted",
        signers: [as_role(ctx.alice, "party_a").signer, as_role(ctx.bob, "party_b").signer],
        payload: %{
          "party_a" => "M-alice",
          "party_b" => "M-bob",
          "denomination" => "USD",
          "a_to_b" => 100,
          "b_to_a" => 60,
          "setoff" => 60,
          "residual_obligation_id" => "OB-NET-1",
          "net_debtor" => "M-alice",
          "net_creditor" => "M-bob",
          "net_minor" => 40
        }
      )

    {:ok, once} = Envelope.sign(env, ctx.alice.signer.key_id, ctx.alice.seed)
    {:ok, twice} = Envelope.sign(once, ctx.bob.signer.key_id, ctx.bob.seed)
    assert {:ok, [_]} = Log.append(twice)

    assert {:error, :source_set_changed} = verify(ctx)
    assert %{open: false} = Log.gate().obligations[{@chapter, "OB-1"}]
    assert %{open: false} = Log.gate().obligations[{@chapter, "OB-2"}]
    assert :ok = Log.verify_chains()
  end

  test "missing or changed legal references cannot silently acquire cryptographic approval", ctx do
    assert {:error, :unverified_or_missing_legal_refs} =
             Proof.prepare(Log.gate(), @chapter, {"M-alice", "M-bob"}, "USD", ctx.sources,
               "SET-1", ctx.grants, %{}
             )

    tampered = put_in(ctx.proof, [:body, "legal_evidence", "jurisdiction"], "OTHER")
    assert {:error, :stale_or_substituted_source_binding} =
             verify(ctx, proof: tampered)
  end
end
