defmodule BarterCore.CrossCurrencyConsentTest do
  use ExUnit.Case, async: true

  alias BarterCore.CrossCurrencyConsent, as: Consent
  alias BarterCore.CrossCurrencySetoff, as: Setoff

  @now 1_800_000_000
  @chapter "pilot-chapter-1"
  @intent "https://alpha.example/clearing/intents/fx-1"

  defp actor(id), do: "https://#{id}.example/actors/merchant"

  defp source(id, debtor, creditor, amount, currency) do
    %{
      id: "https://alpha.example/obligations/#{id}",
      debtor: actor(debtor),
      creditor: actor(creditor),
      amount_minor: amount,
      currency: currency,
      revision: 1,
      evidence_ref: "host-declared-invoice-#{id}",
      valid_until: @now + 1_000,
      status: :host_declared_eligible
    }
  end

  defp rate do
    %{
      base_currency: "EUR",
      quote_currency: "USD",
      numerator: 11,
      denominator: 10,
      agreed_at: @now - 10,
      valid_until: @now + 1_000,
      evidence_ref: "negotiated-rate-reference",
      agreement_ref: "not-verified-commercial-agreement"
    }
  end

  defp sign(proof, ctx) do
    %{
      ctx.a.debtor => %{
        key_id: "business-key-a",
        signature: :crypto.sign(:eddsa, :none, proof.signing_bytes, [ctx.a_seed, :ed25519])
      },
      ctx.b.debtor => %{
        key_id: "business-key-b",
        signature: :crypto.sign(:eddsa, :none, proof.signing_bytes, [ctx.b_seed, :ed25519])
      }
    }
  end

  defp verify(ctx, overrides \\ []) do
    Consent.verify(
      Keyword.get(overrides, :proof, ctx.proof),
      Keyword.get(overrides, :plan, ctx.plan),
      Keyword.get(overrides, :chapter, @chapter),
      Keyword.get(overrides, :hashes, ctx.hashes),
      Keyword.get(overrides, :members, ctx.members),
      Keyword.get(overrides, :signatures, ctx.signatures),
      Keyword.get(overrides, :now, @now)
    )
  end

  setup do
    a = source("usd", "alpha", "beta", 1_000_000, "USD")
    b = source("eur", "beta", "alpha", 800_000, "EUR")
    {:ok, plan} = Setoff.propose(a, b, rate(), @intent, @now)
    {a_pub, a_seed} = :crypto.generate_key(:eddsa, :ed25519)
    {b_pub, b_seed} = :crypto.generate_key(:eddsa, :ed25519)

    hashes = %{
      a.id => :crypto.hash(:sha256, "signed-source-a"),
      b.id => :crypto.hash(:sha256, "signed-source-b")
    }

    members = %{
      a.debtor => %{key_id: "business-key-a", pubkey: a_pub},
      b.debtor => %{key_id: "business-key-b", pubkey: b_pub}
    }

    {:ok, proof} = Consent.prepare(plan, @chapter, hashes, members, @now)
    ctx = %{
      a: a,
      b: b,
      plan: plan,
      hashes: hashes,
      members: members,
      proof: proof,
      a_seed: a_seed,
      b_seed: b_seed
    }
    Map.put(ctx, :signatures, sign(proof, ctx))
  end

  test "two distinct business keys sign the exact original sources, rate and residuals", ctx do
    assert {:ok, result} = verify(ctx)
    assert result.status == :inert_cryptographic_consents_only
    assert result.commitment == ctx.proof.commitment
    assert result.admission == :not_authorized
    assert result.source_authentication == :external_not_verified
    assert result.agency_authority == :external_not_verified
    assert result.contractual_discharge == :not_established
    assert result.currency_exchange == :none
    assert result.financial_settlement == :none

    assert byte_size(ctx.proof.commitment) == 32
    assert ctx.proof.status == :unsigned_inert_source_bound_proposal
    assert length(ctx.proof.sources) == 2
    assert Enum.map(ctx.proof.sources, & &1.source_id) == Enum.sort([ctx.a.id, ctx.b.id])
    assert String.starts_with?(
             ctx.proof.signing_bytes,
             "biz-kit/cross-currency-source-consent/v1\0"
           )

    assert {:ok, same} = Consent.prepare(ctx.plan, @chapter, ctx.hashes, ctx.members, @now)
    assert same == ctx.proof
  end

  test "same-value source substitution invalidates exact source-bound signature", ctx do
    b2 = %{ctx.b | id: "https://alpha.example/obligations/equivalent-eur"}
    {:ok, changed} = Setoff.propose(ctx.a, b2, rate(), @intent, @now)
    hashes2 = %{ctx.a.id => ctx.hashes[ctx.a.id], b2.id => ctx.hashes[ctx.b.id]}

    assert changed.totals_by_currency == ctx.plan.totals_by_currency
    assert {:error, :stale_or_substituted_consent_terms} =
             verify(ctx, plan: changed, hashes: hashes2)

    {:ok, updated} = Consent.prepare(changed, @chapter, hashes2, ctx.members, @now)
    refute updated.commitment == ctx.proof.commitment
    assert {:error, {:invalid_consent, _actor}} =
             Consent.verify(updated, changed, @chapter, hashes2, ctx.members,
               ctx.signatures, @now)
  end

  test "altered original event hashes or source revisions invalidate the signed terms", ctx do
    hashes = Map.put(ctx.hashes, ctx.b.id, :crypto.hash(:sha256, "replacement-history"))
    assert {:error, :stale_or_substituted_consent_terms} = verify(ctx, hashes: hashes)

    {:ok, revised} =
      Setoff.propose(ctx.a, %{ctx.b | revision: ctx.b.revision + 1}, rate(), @intent, @now)

    assert {:error, :stale_or_substituted_consent_terms} = verify(ctx, plan: revised)
  end

  test "changed rate, currency and agreement references invalidate consent", ctx do
    for new_rate <- [
          %{rate() | numerator: 13},
          %{rate() | agreement_ref: "different-agreement"},
          %{rate() | agreed_at: @now - 11},
          %{rate() | evidence_ref: "new-quote"}
        ] do
      {:ok, changed} = Setoff.propose(ctx.a, ctx.b, new_rate, @intent, @now)
      assert {:error, :stale_or_substituted_consent_terms} = verify(ctx, plan: changed)
    end

    b = %{ctx.b | currency: "GBP"}
    {:ok, changed} =
      Setoff.propose(ctx.a, b, %{rate() | base_currency: "GBP"}, @intent, @now)

    assert {:error, :stale_or_substituted_consent_terms} = verify(ctx, plan: changed)
  end

  test "missing, mismatched, swapped, invalid or extra signatures fail closed", ctx do
    signatures = Map.delete(ctx.signatures, ctx.a.debtor)
    assert {:error, :two_independent_consents_required} =
             verify(ctx, signatures: signatures)

    signatures = Map.put(ctx.signatures, "https://extra.example/actor", %{key_id: "x"})
    assert {:error, :two_independent_consents_required} =
             verify(ctx, signatures: signatures)

    signatures =
      put_in(ctx.signatures, [ctx.b.debtor, :signature],
        ctx.signatures[ctx.a.debtor].signature)

    assert {:error, {:invalid_consent, _}} = verify(ctx, signatures: signatures)

    signatures = put_in(ctx.signatures, [ctx.b.debtor, :key_id], "old-key")
    assert {:error, {:invalid_consent, _}} = verify(ctx, signatures: signatures)

    signatures = put_in(ctx.signatures, [ctx.b.debtor, :signature], <<0::512>>)
    assert {:error, {:invalid_consent, _}} = verify(ctx, signatures: signatures)

    signatures =
      Map.update!(ctx.signatures, ctx.a.debtor, &Map.put(&1, :authority_claim, true))

    assert {:error, {:invalid_consent, _}} = verify(ctx, signatures: signatures)
  end

  test "key rotation, substituted registry, common key and extra authority fields fail", ctx do
    {rotated_pub, _} = :crypto.generate_key(:eddsa, :ed25519)
    updated = put_in(ctx.members, [ctx.b.debtor, :pubkey], rotated_pub)
    assert {:error, :stale_or_substituted_consent_terms} =
             verify(ctx, members: updated)

    duplicate = put_in(ctx.members, [ctx.b.debtor, :pubkey], ctx.members[ctx.a.debtor].pubkey)
    assert {:error, :missing_or_nonindependent_business_keys} =
             Consent.prepare(ctx.plan, @chapter, ctx.hashes, duplicate, @now)

    duplicate = put_in(ctx.members, [ctx.b.debtor, :key_id], "business-key-a")
    assert {:error, :missing_or_nonindependent_business_keys} =
             Consent.prepare(ctx.plan, @chapter, ctx.hashes, duplicate, @now)

    extra = Map.put(ctx.members[ctx.b.debtor], :host_certified, true)
    assert {:error, :invalid_business_key_record} =
             Consent.prepare(ctx.plan, @chapter, ctx.hashes,
               Map.put(ctx.members, ctx.b.debtor, extra), @now)
  end

  test "future, expired and stale inputs cannot be accepted as fresh consents", ctx do
    assert {:error, :expired_source_or_rate} =
             verify(ctx, now: @now + 1_000)

    assert {:error, :invalid_observation_time} =
             Consent.prepare(ctx.plan, @chapter, ctx.hashes, ctx.members, @now - 1)

    assert {:error, :invalid_chapter} =
             Consent.prepare(ctx.plan, "", ctx.hashes, ctx.members, @now)
  end

  test "missing, extra or malformed source-event hashes are rejected", ctx do
    assert {:error, :missing_or_invalid_source_hashes} =
             Consent.prepare(ctx.plan, @chapter, %{}, ctx.members, @now)

    assert {:error, :missing_or_invalid_source_hashes} =
             Consent.prepare(ctx.plan, @chapter,
               Map.put(ctx.hashes, ctx.a.id, "not-a-digest"), ctx.members, @now)

    assert {:error, :missing_or_invalid_source_hashes} =
             Consent.prepare(ctx.plan, @chapter,
               Map.put(ctx.hashes, "bogus-source", <<0::256>>), ctx.members, @now)
  end

  test "proof tampering and changed context cannot be interpreted as effective discharge", ctx do
    for invalid <- [
          %{ctx.proof | signing_bytes: "other"},
          %{ctx.proof | commitment: <<0::256>>},
          %{ctx.proof | chapter_id: "another-chapter"},
          %{ctx.proof | contractual_discharge: :completed},
          %{ctx.proof | financial_settlement: :complete}
        ] do
      assert {:error, :stale_or_substituted_consent_terms} =
               verify(ctx, proof: invalid)
    end

    assert {:error, :stale_or_substituted_consent_terms} =
             verify(ctx, chapter: "different-valid-chapter")
  end

  test "this isolated crypto path creates no signed business events or payment effects", ctx do
    assert {:ok, _} = verify(ctx)

    refute Map.has_key?(ctx.proof, :signed_event)
    refute Map.has_key?(ctx.proof, :ledger_append)
    refute Map.has_key?(ctx.proof, :source_reservation)
    refute Map.has_key?(ctx.proof, :cash_transfer)
    refute Map.has_key?(ctx.proof, :journal_postings)
    refute Map.has_key?(ctx.proof, :regulatory_permission)

    assert {:error, :invalid_verification_request} =
             Consent.verify(nil, nil, nil, nil, nil, nil, nil)
  end
end
