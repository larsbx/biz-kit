defmodule CoopSubstrate.ObligationRailTest do
  @moduledoc """
  Phase 1C step 4 (docs/phase1c_plan.md P5–P6) over the real log: the
  obligation-relationship rail (corpus 05 §1.2). Obligations, assignments,
  and discharges are dual-signed by the parties' CURRENT keys; illegal facts
  (unknown parties, duplicate ids, self-obligation, double discharge,
  assignment on closed obligations, stale/foreign party keys) are rejected
  at the append gate, before persistence, chains intact. Money movement is
  not representable — discharge is attestation of external settlement.
  """

  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.Log
  alias CoopSubstrate.Projections.Membership

  @chapter "chapter-genesis"

  setup do
    alice = new_member("member")
    bob = new_member("member")

    for {id, actor} <- [{"M-alice", alice}, {"M-bob", bob}] do
      {:ok, _} =
        Log.append(signed_event(actor, "MemberRegistered", registration_payload(id, actor)))
    end

    %{alice: alice, bob: bob}
  end

  defp as_role(actor, role), do: %{actor | signer: %{actor.signer | role: role}}

  defp record(debtor, creditor, attrs \\ []) do
    payload =
      Map.merge(
        %{
          "obligation_id" => "OB-1",
          "debtor_id" => "M-alice",
          "creditor_id" => "M-bob",
          "amount_minor" => 50_000,
          "denomination" => "USD"
        },
        Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
      )

    multi_signed_event([as_role(debtor, "debtor"), as_role(creditor, "creditor")],
      "ObligationRecorded",
      payload
    )
  end

  defp discharge(debtor, creditor, obligation_id \\ "OB-1") do
    multi_signed_event([as_role(debtor, "debtor"), as_role(creditor, "creditor")],
      "ObligationDischarged",
      %{"obligation_id" => obligation_id}
    )
  end

  defp assert_rejected(envelope, expected_reason) do
    before_head = Log.head()
    assert {:error, {:reject, _i, reason}} = Log.append(envelope)
    assert reason == expected_reason
    assert Log.head() == before_head
    assert :ok = Log.verify_chains()
  end

  defp obligation(id \\ "OB-1") do
    {:ok, state} = Log.replay(Membership)
    state.obligations[{@chapter, id}]
  end

  test "record → discharge, dual-signed; the relationship is the state, never funds", ctx do
    {:ok, _} = Log.append(record(ctx.alice, ctx.bob))

    assert %{debtor_id: "M-alice", creditor_id: "M-bob", amount_minor: 50_000, open: true} =
             obligation()

    {:ok, _} = Log.append(discharge(ctx.alice, ctx.bob))
    assert %{open: false} = obligation()
    assert :ok = Log.verify_chains()
  end

  test "duplicate obligation ids, self-obligation, unknown parties, bad amounts", ctx do
    {:ok, _} = Log.append(record(ctx.alice, ctx.bob))

    assert_rejected(record(ctx.alice, ctx.bob), {:obligation_already_recorded, "OB-1"})

    # A same-key dual signature is already unrepresentable at the envelope
    # layer (duplicate key_id); a self-referencing payload dies at the gate.
    assert_rejected(
      record(ctx.alice, ctx.bob, obligation_id: "OB-2", creditor_id: "M-alice"),
      :self_obligation
    )

    assert_rejected(
      record(ctx.alice, ctx.bob, obligation_id: "OB-2", creditor_id: "M-carol"),
      {:unregistered_member, "M-carol"}
    )

    assert_rejected(
      record(ctx.alice, ctx.bob, obligation_id: "OB-2", amount_minor: 0),
      :amount_must_be_positive
    )
  end

  test "party signatures must be the parties' current keys", ctx do
    imposter = new_member("member")

    assert_rejected(
      record(imposter, ctx.bob),
      {:wrong_key_for_role, "debtor", imposter.signer.key_id}
    )

    {:ok, _} = Log.append(record(ctx.alice, ctx.bob))

    # Bob rotates (self-signed, 1D gate); his OLD key can no longer attest a
    # discharge.
    rotated_bob = new_member("member")

    {:ok, _} =
      Log.append(
        signed_event(as_role(ctx.bob, "author"), "KeyRotated", %{
          "member_id" => "M-bob",
          "old_key_id" => ctx.bob.signer.key_id,
          "new_key_id" => rotated_bob.signer.key_id,
          "new_pubkey" => {:bytes, rotated_bob.signer.pubkey}
        })
      )

    assert_rejected(
      discharge(ctx.alice, ctx.bob),
      {:wrong_key_for_role, "creditor", ctx.bob.signer.key_id}
    )

    {:ok, _} = Log.append(discharge(ctx.alice, rotated_bob))
    assert %{open: false} = obligation()
  end

  test "assignment substitutes the debtor; discharge then binds the NEW debtor", ctx do
    carol = new_member("member")
    {:ok, _} = Log.append(signed_event(carol, "MemberRegistered", registration_payload("M-carol", carol)))
    {:ok, _} = Log.append(record(ctx.alice, ctx.bob))

    {:ok, _} =
      Log.append(
        multi_signed_event([as_role(ctx.alice, "assignor"), as_role(carol, "assignee")],
          "ObligationAssigned",
          %{"obligation_id" => "OB-1", "new_debtor_id" => "M-carol"}
        )
      )

    assert %{debtor_id: "M-carol", open: true} = obligation()

    # Alice is out of the relationship: her debtor signature no longer counts.
    assert_rejected(
      discharge(ctx.alice, ctx.bob),
      {:wrong_key_for_role, "debtor", ctx.alice.signer.key_id}
    )

    {:ok, _} = Log.append(discharge(carol, ctx.bob))
    assert %{open: false} = obligation()
  end

  test "assignment requires an open obligation, a registered assignee, distinct parties", ctx do
    carol = new_member("member")
    {:ok, _} = Log.append(signed_event(carol, "MemberRegistered", registration_payload("M-carol", carol)))

    assign = fn assignor, assignee, payload ->
      multi_signed_event([as_role(assignor, "assignor"), as_role(assignee, "assignee")],
        "ObligationAssigned",
        payload
      )
    end

    assert_rejected(
      assign.(ctx.alice, carol, %{"obligation_id" => "OB-404", "new_debtor_id" => "M-carol"}),
      {:no_such_obligation, "OB-404"}
    )

    {:ok, _} = Log.append(record(ctx.alice, ctx.bob))

    # Assignment collapsing debtor onto the creditor reconstructs a discharge
    # without dual attestation — rejected as self-obligation.
    assert_rejected(
      assign.(ctx.alice, ctx.bob, %{"obligation_id" => "OB-1", "new_debtor_id" => "M-bob"}),
      :self_obligation
    )

    {:ok, _} = Log.append(discharge(ctx.alice, ctx.bob))

    assert_rejected(
      assign.(ctx.alice, carol, %{"obligation_id" => "OB-1", "new_debtor_id" => "M-carol"}),
      :obligation_discharged
    )
  end

  test "discharge-once: a second discharge is rejected before persistence", ctx do
    {:ok, _} = Log.append(record(ctx.alice, ctx.bob))
    {:ok, _} = Log.append(discharge(ctx.alice, ctx.bob))

    assert_rejected(discharge(ctx.alice, ctx.bob), :obligation_discharged)
  end

  test "obligations are chapter-scoped", ctx do
    {:ok, _} = Log.append(record(ctx.alice, ctx.bob))

    # Same id in another chapter: no such obligation (and no such members).
    assert_rejected(
      multi_signed_event([as_role(ctx.alice, "debtor"), as_role(ctx.bob, "creditor")],
        "ObligationDischarged",
        %{"obligation_id" => "OB-1"},
        chapter_id: "chapter-two"
      ),
      {:no_such_obligation, "OB-1"}
    )
  end
end
