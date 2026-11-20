defmodule CoopSubstrate.CrossCurrencySourceSnapshotTest do
  @moduledoc """
  Authenticated local signed source history; no authenticated commercial
  invoice, corporate mandate, legal classification, or discharge.
  """

  use CoopSubstrate.LogCase, async: false

  alias BarterCore.CrossCurrencyConsent
  alias BarterCore.CrossCurrencySetoff
  alias CoopSubstrate.CrossCurrencySourceSnapshot, as: Snapshot
  alias CoopSubstrate.Log
  alias CoopSubstrate.Protocol.Envelope

  @chapter "chapter-genesis"
  @alice "https://alice.example/actors/merchant"
  @bob "https://bob.example/actors/merchant"
  @usd "https://alice.example/obligations/usd-1"
  @eur "https://bob.example/obligations/eur-1"
  @now 1_800_000_000

  setup do
    alice = new_member("member")
    bob = new_member("member")
    carol = new_member("member")

    for {id, actor} <- [{@alice, alice}, {@bob, bob}, {"M-carol", carol}] do
      {:ok, [_]} =
        Log.append(signed_event(actor, "MemberRegistered", registration_payload(id, actor)))
    end

    %{alice: alice, bob: bob, carol: carol}
  end

  defp role(actor, name), do: %{actor | signer: %{actor.signer | role: name}}

  defp record!(debtor, creditor, id, debtor_id, creditor_id, amount, currency) do
    {:ok, [event]} =
      Log.append(
        multi_signed_event(
          [role(debtor, "debtor"), role(creditor, "creditor")],
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

  defp pair!(ctx, denomination \\ "EUR") do
    a = record!(ctx.alice, ctx.bob, @usd, @alice, @bob, 1_000_000, "USD")
    b = record!(ctx.bob, ctx.alice, @eur, @bob, @alice, 800_000, denomination)
    {a, b}
  end

  defp snapshot, do: Snapshot.snapshot(@chapter, {@usd, @eur})

  defp plan do
    a = %{
      id: @usd,
      debtor: @alice,
      creditor: @bob,
      currency: "USD",
      amount_minor: 1_000_000,
      revision: 1,
      evidence_ref: "asserted-invoice-usd",
      valid_until: @now + 2_000,
      status: :host_declared_eligible
    }

    b = %{
      id: @eur,
      debtor: @bob,
      creditor: @alice,
      currency: "EUR",
      amount_minor: 800_000,
      revision: 1,
      evidence_ref: "asserted-invoice-eur",
      valid_until: @now + 2_000,
      status: :host_declared_eligible
    }

    rate = %{
      base_currency: "EUR",
      quote_currency: "USD",
      numerator: 11,
      denominator: 10,
      agreed_at: @now - 1,
      valid_until: @now + 2_000,
      evidence_ref: "host-asserted-agreed-valuation",
      agreement_ref: "host-asserted-terms-only"
    }

    {:ok, value} =
      CrossCurrencySetoff.propose(
        a,
        b,
        rate,
        "https://alice.example/clearing/intent-1",
        @now
      )

    value
  end

  defp sign(proof, ctx) do
    %{
      @alice => %{
        key_id: ctx.alice.signer.key_id,
        signature: :crypto.sign(:eddsa, :none, proof.signing_bytes, [ctx.alice.seed, :ed25519])
      },
      @bob => %{
        key_id: ctx.bob.signer.key_id,
        signature: :crypto.sign(:eddsa, :none, proof.signing_bytes, [ctx.bob.seed, :ed25519])
      }
    }
  end

  test "reconstructs two separately signed original sources and current member keys", ctx do
    {a, b} = pair!(ctx)
    original_head = Log.head()

    assert {:ok, result} = snapshot()
    assert result.observed_head == original_head
    assert result.source_status == :authenticated_local_original_business_history
    assert result.agency_status == :unverified
    assert result.legal_classification == :undetermined
    assert result.admission == :not_authorized
    assert result.discharge == :none
    assert result.currency_exchange == :none

    {:ok, a_hash} = Envelope.event_hash(a)
    {:ok, b_hash} = Envelope.event_hash(b)

    assert result.source_hashes == %{@usd => a_hash, @eur => b_hash}
    assert result.sources[@usd].currency == "USD"
    assert result.sources[@eur].currency == "EUR"
    assert result.sources[@usd].revision == 1

    assert result.members[@alice] == %{
             key_id: ctx.alice.signer.key_id,
             pubkey: ctx.alice.signer.pubkey
           }

    assert result.members[@bob].pubkey == ctx.bob.signer.pubkey

    {:ok, source_core} = Envelope.signing_bytes(a)

    assert result.sources[@usd].original_signed_core_digest ==
             :crypto.hash(:sha256, source_core)

    assert :ok = Log.verify_chains()
    assert Log.head() == original_head
  end

  test "feeds independently obtained originals into inert two-party FX consent", ctx do
    pair!(ctx)
    {:ok, current} = snapshot()
    candidate = plan()

    assert {:ok, consent} =
             CrossCurrencyConsent.prepare(
               candidate,
               @chapter,
               current.source_hashes,
               current.members,
               @now
             )

    assert {:ok, result} =
             CrossCurrencyConsent.verify(
               consent,
               candidate,
               @chapter,
               current.source_hashes,
               current.members,
               sign(consent, ctx),
               @now
             )

    assert result.status == :inert_cryptographic_consents_only
    assert result.source_authentication == :external_not_verified
    assert result.agency_authority == :external_not_verified
    assert result.admission == :not_authorized
    assert result.contractual_discharge == :not_established
    assert result.financial_settlement == :none
    assert Log.gate().obligations[{@chapter, @usd}].open == true
    assert Log.gate().obligations[{@chapter, @eur}].open == true
  end

  test "same-value substitute has distinct original IDs and cannot reuse the old source hash",
       ctx do
    pair!(ctx)
    {:ok, before} = snapshot()

    {:ok, [_]} =
      Log.append(
        multi_signed_event(
          [role(ctx.bob, "debtor"), role(ctx.alice, "creditor")],
          "ObligationDischarged",
          %{"obligation_id" => @eur}
        )
      )

    replacement = "https://bob.example/obligations/eur-2"
    record!(ctx.bob, ctx.alice, replacement, @bob, @alice, 800_000, "EUR")

    assert {:error, :missing_or_closed_original_source} = snapshot()

    assert {:ok, after_snapshot} = Snapshot.snapshot(@chapter, {@usd, replacement})
    assert after_snapshot.sources[replacement].amount_minor == 800_000
    refute after_snapshot.source_hashes[replacement] == before.source_hashes[@eur]
    assert Map.keys(after_snapshot.source_hashes) != Map.keys(before.source_hashes)
  end

  test "assignment away and back is never accepted as an original source", ctx do
    pair!(ctx)
    assert {:ok, _} = snapshot()

    {:ok, [_]} =
      Log.append(
        multi_signed_event(
          [role(ctx.alice, "assignor"), role(ctx.carol, "assignee")],
          "ObligationAssigned",
          %{"obligation_id" => @usd, "new_debtor_id" => "M-carol"}
        )
      )

    {:ok, [_]} =
      Log.append(
        multi_signed_event(
          [role(ctx.carol, "assignor"), role(ctx.alice, "assignee")],
          "ObligationAssigned",
          %{"obligation_id" => @usd, "new_debtor_id" => @alice}
        )
      )

    assert {:error, {:unsupported_or_tampered_source_history, @usd}} = snapshot()
    assert :ok = Log.verify_chains()
  end

  test "same denomination, nonreciprocal and missing sources fail closed", ctx do
    pair!(ctx, "USD")
    assert {:error, :same_currency_use_original_setoff} = snapshot()

    assert {:error, :missing_or_closed_original_source} =
             Snapshot.snapshot(@chapter, {@usd, "https://missing.example/obligations/x"})

    assert {:error, :invalid_source_pair} = Snapshot.snapshot(@chapter, {@usd, @usd})
    assert {:error, :invalid_request} = Snapshot.snapshot("", {@usd, @eur})
  end

  test "current rotated key changes the source snapshot without changing source hashes", ctx do
    pair!(ctx)
    {:ok, before} = snapshot()
    replacement = new_member("member")

    {:ok, [_]} =
      Log.append(
        signed_event(
          role(ctx.bob, "author"),
          "KeyRotated",
          %{
            "member_id" => @bob,
            "old_key_id" => ctx.bob.signer.key_id,
            "new_key_id" => replacement.signer.key_id,
            "new_pubkey" => {:bytes, replacement.signer.pubkey}
          }
        )
      )

    assert {:ok, after_rotation} = snapshot()
    assert after_rotation.source_hashes == before.source_hashes
    assert after_rotation.members[@bob].key_id == replacement.signer.key_id

    {:ok, old_consent} =
      CrossCurrencyConsent.prepare(plan(), @chapter, before.source_hashes, before.members, @now)

    assert {:error, :stale_or_substituted_consent_terms} =
             CrossCurrencyConsent.verify(
               old_consent,
               plan(),
               @chapter,
               after_rotation.source_hashes,
               after_rotation.members,
               sign(old_consent, ctx),
               @now
             )
  end

  test "restart recreates the same authenticated source digests and key set", ctx do
    pair!(ctx)
    assert {:ok, before} = snapshot()
    restart_log()
    assert {:ok, after_restart} = snapshot()
    assert before.source_hashes == after_restart.source_hashes
    assert before.members == after_restart.members
    assert before.sources == after_restart.sources
    assert :ok = Log.verify_chains()
  end
end
