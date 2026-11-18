defmodule CoopSubstrate.CommercialSetoffTest do
  @moduledoc """
  Ledger-first bilateral commercial setoff bridge: no second financial
  writer; unsigned proposals and separate dual-signed authoritative
  Log admissions under the already existing NettingExecuted gate.
  """
  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.CommercialSetoff
  alias CoopSubstrate.Finance
  alias CoopSubstrate.Log
  alias CoopSubstrate.Protocol.Envelope
  alias CoopSubstrate.Projections.Membership

  @chapter "chapter-genesis"

  setup do
    alice = new_member("member")
    bob = new_member("member")

    for {member_id, actor} <- [{"M-alice", alice}, {"M-bob", bob}] do
      {:ok, _} =
        Log.append(
          signed_event(actor, "MemberRegistered", registration_payload(member_id, actor))
        )
    end

    %{alice: alice, bob: bob}
  end

  defp role(actor, role), do: %{actor | signer: %{actor.signer | role: role}}

  defp record!(debtor, creditor, id, debtor_id, creditor_id, amount, denomination \\ "USD") do
    {:ok, [_]} =
      Log.append(
        multi_signed_event(
          [role(debtor, "debtor"), role(creditor, "creditor")],
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

  defp seed_pair!(ctx) do
    record!(ctx.alice, ctx.bob, "OB-1", "M-alice", "M-bob", 100)
    record!(ctx.bob, ctx.alice, "OB-2", "M-bob", "M-alice", 60)
  end

  defp prepare(residual_id \\ "OB-NET-1") do
    CommercialSetoff.prepare(
      @chapter,
      {"M-alice", "M-bob"},
      "USD",
      residual_id,
      System.system_time(:millisecond)
    )
  end

  defp dual_sign(envelope, ctx) do
    {:ok, first} = Envelope.sign(envelope, ctx.alice.signer.key_id, ctx.alice.seed)
    {:ok, second} = Envelope.sign(first, ctx.bob.signer.key_id, ctx.bob.seed)
    second
  end

  test "prepares exact unsigned bilateral claim from authoritative gate, not money", ctx do
    seed_pair!(ctx)
    before_head = Log.head()
    assert {:ok, proposal} = prepare()

    assert proposal.source_obligation_ids == ["OB-1", "OB-2"]
    assert proposal.status == :unsigned_not_legally_cleared
    assert proposal.source_binding == :not_signed_by_existing_event_schema
    assert proposal.legal_evidence == :not_verified
    assert proposal.financial_settlement == :none
    assert proposal.action == :independent_dual_signature_and_admission_required
    assert proposal.envelope.type == "NettingExecuted"
    assert proposal.envelope.sigs == %{}

    assert proposal.envelope.payload == %{
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

    assert Log.head() == before_head
  end

  test "requires both current party keys; only signed Log append changes books", ctx do
    seed_pair!(ctx)
    assert {:ok, %{envelope: envelope}} = prepare()
    before_head = Log.head()

    assert {:error, {:reject, _, _}} = Log.append(envelope)
    assert Log.head() == before_head

    {:ok, singly_signed} =
      Envelope.sign(envelope, ctx.alice.signer.key_id, ctx.alice.seed)

    assert {:error, {:reject, _, _}} = Log.append(singly_signed)
    assert Log.head() == before_head

    {:ok, [accepted]} = Log.append(dual_sign(envelope, ctx))
    assert accepted.type == "NettingExecuted"
    assert accepted.global_seq > before_head.global_seq

    assert %{open: false} = Log.gate().obligations[{@chapter, "OB-1"}]
    assert %{open: false} = Log.gate().obligations[{@chapter, "OB-2"}]

    assert %{open: true, amount_minor: 40} =
             Log.gate().obligations[{@chapter, "OB-NET-1"}]

    assert {:error, :nothing_to_net} = prepare("OB-NET-2")

    assert {:ok, [%{a_to_b: 40, b_to_a: 0, setoff: 0}]} =
             Finance.netting(@chapter, {"M-alice", "M-bob"})

    assert :ok = Log.verify_chains()
    restart_log()

    assert %{open: true, amount_minor: 40} =
             Log.gate().obligations[{@chapter, "OB-NET-1"}]

    assert {:ok, state} = Log.replay(Membership)
    assert state.obligations == Log.gate().obligations
  end

  test "stale unsigned proposal cannot discharge a changed obligation pair", ctx do
    seed_pair!(ctx)
    assert {:ok, %{envelope: envelope}} = prepare()
    record!(ctx.alice, ctx.bob, "OB-3", "M-alice", "M-bob", 10)

    before_head = Log.head()
    assert {:error, {:reject, _, :netting_mismatch}} = Log.append(dual_sign(envelope, ctx))
    assert Log.head() == before_head
    assert %{open: true} = Log.gate().obligations[{@chapter, "OB-1"}]
    assert %{open: true} = Log.gate().obligations[{@chapter, "OB-2"}]
    assert :ok = Log.verify_chains()
  end

  test "member key rotation invalidates already drafted and signed netting", ctx do
    seed_pair!(ctx)
    assert {:ok, %{envelope: envelope}} = prepare()
    signed = dual_sign(envelope, ctx)
    replacement = new_member("member")

    {:ok, [_]} =
      Log.append(
        signed_event(role(ctx.bob, "author"), "KeyRotated", %{
          "member_id" => "M-bob",
          "old_key_id" => ctx.bob.signer.key_id,
          "new_key_id" => replacement.signer.key_id,
          "new_pubkey" => {:bytes, replacement.signer.pubkey}
        })
      )

    before_head = Log.head()
    assert {:error, {:reject, _, {:wrong_key_for_role, "party_b", _}}} = Log.append(signed)
    assert Log.head() == before_head
    assert {:ok, %{envelope: new_envelope}} = prepare()
    assert Enum.at(new_envelope.signers, 1).key_id == replacement.signer.key_id
  end

  test "refuses empty, unregistered, unsorted, one-way, cross-currency or reused residual IDs",
       ctx do
    record!(ctx.alice, ctx.bob, "OB-1", "M-alice", "M-bob", 100)
    assert {:error, :nothing_to_net} = prepare()

    assert {:error, :invalid_pair_or_denomination} =
             CommercialSetoff.prepare(@chapter, {"M-bob", "M-alice"}, "USD", "x", 5)

    assert {:error, {:unregistered_or_invalid_member, "M-charlie"}} =
             CommercialSetoff.prepare(@chapter, {"M-alice", "M-charlie"}, "USD", "x", 5)

    record!(ctx.bob, ctx.alice, "OB-2", "M-bob", "M-alice", 100, "EUR")
    assert {:error, :nothing_to_net} = prepare()

    record!(ctx.bob, ctx.alice, "OB-3", "M-bob", "M-alice", 60)
    assert {:error, :invalid_residual_id} = prepare(nil)
    assert {:error, :residual_id_already_used} = prepare("OB-1")

    assert {:ok, %{envelope: valid}} = prepare("OB-NET-1")
    refute Map.has_key?(valid.payload, "source_obligation_ids")
  end

  test "equal bilateral position needs no residual and duplicate signed event cannot discharge twice",
       ctx do
    record!(ctx.alice, ctx.bob, "OB-1", "M-alice", "M-bob", 30)
    record!(ctx.bob, ctx.alice, "OB-2", "M-bob", "M-alice", 30)

    assert {:ok, %{envelope: env}} = prepare(nil)
    refute Map.has_key?(env.payload, "residual_obligation_id")
    signed = dual_sign(env, ctx)

    assert {:ok, [_]} = Log.append(signed)
    head_after = Log.head()

    # The appender may recognize exact event replay; either way no new debit,
    # credit, balance or financial custody can be inferred from the duplicate.
    _ = Log.append(signed)
    assert Log.head() == head_after
    assert {:error, :nothing_to_net} = prepare(nil)
    assert :ok = Log.verify_chains()
  end
end
