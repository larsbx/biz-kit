defmodule CoopSubstrate.CommercialSetoffIntentTest do
  @moduledoc """
  Real, signed, canonical business-log admission for exact-source
  COMMERCIAL PROPOSALS ONLY. No source discharge or company agency is proven.
  """
  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.Canonical
  alias CoopSubstrate.CommercialSetoffIntent
  alias CoopSubstrate.Log
  alias CoopSubstrate.Projections.Membership
  alias CoopSubstrate.Protocol.Envelope

  @chapter "chapter-genesis"

  setup do
    alice = new_member("member")
    bob = new_member("member")

    for {member_id, actor} <- [{"M-alice", alice}, {"M-bob", bob}] do
      {:ok, [_]} =
        Log.append(
          signed_event(actor, "MemberRegistered", registration_payload(member_id, actor))
        )
    end

    %{alice: alice, bob: bob}
  end

  defp as_role(actor, role), do: %{actor | signer: %{actor.signer | role: role}}

  defp record!(debtor, creditor, id, debtor_id, creditor_id, amount, denomination \\ "USD") do
    {:ok, [_]} =
      Log.append(
        multi_signed_event(
          [as_role(debtor, "debtor"), as_role(creditor, "creditor")],
          "ObligationRecorded",
          %{
            "obligation_id" => id,
            "debtor_id" => debtor_id,
            "creditor_id" => creditor_id,
            "amount_minor" => amount,
            "denomination" => denomination
          }
        )
      )
  end

  defp seed!(ctx) do
    record!(ctx.alice, ctx.bob, "OB-1", "M-alice", "M-bob", 100)
    record!(ctx.bob, ctx.alice, "OB-2", "M-bob", "M-alice", 60)
  end

  defp source(id, debtor, creditor, amount, denomination \\ "USD") do
    %{
      "obligation_id" => id,
      "debtor_id" => debtor,
      "creditor_id" => creditor,
      "amount_minor" => amount,
      "denomination" => denomination
    }
  end

  defp sources do
    [
      source("OB-1", "M-alice", "M-bob", 100),
      source("OB-2", "M-bob", "M-alice", 60)
    ]
  end

  defp payload(intention \\ "SET-1", selected \\ nil) do
    selected = selected || sources()
    {:ok, digest} = Canonical.hash(selected)

    %{
      "intent_id" => intention,
      "party_a" => "M-alice",
      "party_b" => "M-bob",
      "denomination" => "USD",
      "sources" => selected,
      "source_terms_digest" => {:bytes, digest},
      "a_to_b" => 100,
      "b_to_a" => 60,
      "setoff" => 60
    }
  end

  defp unsigned(ctx, p) do
    {:ok, env} =
      Envelope.new(
        type: CommercialSetoffIntent.event_type(),
        chapter_id: @chapter,
        payload: p,
        timestamp_ms: System.system_time(:millisecond),
        signers: [as_role(ctx.alice, "party_a").signer, as_role(ctx.bob, "party_b").signer]
      )

    env
  end

  defp dual_sign(env, ctx) do
    {:ok, a} = Envelope.sign(env, ctx.alice.signer.key_id, ctx.alice.seed)
    {:ok, b} = Envelope.sign(a, ctx.bob.signer.key_id, ctx.bob.seed)
    b
  end

  defp reject!(env, reason) do
    head = Log.head()
    assert {:error, {:reject, _index, ^reason}} = Log.append(env)
    assert Log.head() == head
  end

  test "an exact-source dual-signed intent records only a proposal; all debts stay open", ctx do
    seed!(ctx)

    pending = unsigned(ctx, payload())
    reject!(pending, {:missing_signature, ctx.alice.signer.key_id})

    {:ok, only_a} = Envelope.sign(pending, ctx.alice.signer.key_id, ctx.alice.seed)
    reject!(only_a, {:missing_signature, ctx.bob.signer.key_id})

    {:ok, [event]} = Log.append(dual_sign(pending, ctx))
    assert event.type == "CommercialSetoffIntentRecordedV1"

    gate = Log.gate()

    assert gate.commercial_setoff_intents[{@chapter, "SET-1"}].status ==
             :signed_proposal_not_discharge

    assert gate.commercial_setoff_intents[{@chapter, "SET-1"}].settlement == :none
    assert gate.commercial_setoff_intents[{@chapter, "SET-1"}].sources == sources()
    assert gate.obligations[{@chapter, "OB-1"}].open
    assert gate.obligations[{@chapter, "OB-2"}].open

    assert :ok = Log.verify_chains()
    restart_log()
    assert Log.gate().commercial_setoff_intents[{@chapter, "SET-1"}].sources == sources()
    assert Log.gate().obligations[{@chapter, "OB-1"}].open
  end

  test "same aggregate, substituted source identity is rejected before append", ctx do
    seed!(ctx)
    signed = dual_sign(unsigned(ctx, payload()), ctx)

    {:ok, [_]} =
      Log.append(
        multi_signed_event(
          [as_role(ctx.bob, "debtor"), as_role(ctx.alice, "creditor")],
          "ObligationDischarged",
          %{"obligation_id" => "OB-2"}
        )
      )

    record!(ctx.bob, ctx.alice, "OB-3", "M-bob", "M-alice", 60)

    reject!(signed, :commercial_setoff_source_mismatch)
    assert Log.gate().commercial_setoff_intents == %{}
    assert :ok = Log.verify_chains()
  end

  test "digest and source quantity or ordering cannot be substituted", ctx do
    seed!(ctx)
    p = payload()

    reject!(
      dual_sign(
        unsigned(ctx, %{p | "source_terms_digest" => {:bytes, :crypto.hash(:sha256, "wrong")}}),
        ctx
      ),
      :commercial_setoff_digest_mismatch
    )

    reject!(
      dual_sign(unsigned(ctx, %{p | "sources" => Enum.reverse(sources())}), ctx),
      :commercial_setoff_source_mismatch
    )

    replacement = [hd(sources()), source("OB-2", "M-bob", "M-alice", 61)]

    reject!(
      dual_sign(unsigned(ctx, payload("SET-OTHER", replacement)), ctx),
      :commercial_setoff_source_mismatch
    )
  end

  test "a different envelope with the same intent cannot create duplicate proposals", ctx do
    seed!(ctx)
    original = dual_sign(unsigned(ctx, payload()), ctx)
    assert {:ok, [_]} = Log.append(original)
    head = Log.head()

    exact_response = Log.append(original)
    assert match?({:ok, [_]}, exact_response) or match?({:error, _}, exact_response)
    assert Log.head() == head

    reject!(dual_sign(unsigned(ctx, payload()), ctx), :commercial_setoff_intent_replayed)
    assert Log.gate().obligations[{@chapter, "OB-2"}].open
  end

  test "key rotation denies a signed intent prepared before the rotation", ctx do
    seed!(ctx)
    old = dual_sign(unsigned(ctx, payload()), ctx)
    new_bob = new_member("member")

    {:ok, [_]} =
      Log.append(
        signed_event(as_role(ctx.bob, "author"), "KeyRotated", %{
          "member_id" => "M-bob",
          "old_key_id" => ctx.bob.signer.key_id,
          "new_key_id" => new_bob.signer.key_id,
          "new_pubkey" => {:bytes, new_bob.signer.pubkey}
        })
      )

    reject!(old, {:stale_commercial_setoff_signer, "party_b"})
  end

  test "no cross currency and no one-way setoff is recorded", ctx do
    record!(ctx.alice, ctx.bob, "OB-1", "M-alice", "M-bob", 100)
    record!(ctx.bob, ctx.alice, "OB-2", "M-bob", "M-alice", 60, "EUR")
    reject!(dual_sign(unsigned(ctx, payload()), ctx), :commercial_setoff_source_mismatch)

    assert {:ok, state} = Log.replay(Membership)
    assert state.commercial_setoff_intents == %{}
  end
end
