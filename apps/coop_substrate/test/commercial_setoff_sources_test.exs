defmodule CoopSubstrate.CommercialSetoffSourcesTest do
  @moduledoc """
  Actual signed local-log source extraction. No tested action represents a
  lawful setoff agreement, transfer of value, or corporate authority.
  """

  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.CommercialSetoffProof
  alias CoopSubstrate.CommercialSetoffSources
  alias CoopSubstrate.Log
  alias CoopSubstrate.Protocol.Envelope

  @chapter "chapter-genesis"

  setup do
    alice = new_member("member")
    bob = new_member("member")
    carol = new_member("member")

    for {member_id, actor} <- [{"M-alice", alice}, {"M-bob", bob}, {"M-carol", carol}] do
      {:ok, [_]} =
        Log.append(signed_event(actor, "MemberRegistered", registration_payload(member_id, actor)))
    end

    %{alice: alice, bob: bob, carol: carol}
  end

  defp role(actor, name), do: %{actor | signer: %{actor.signer | role: name}}

  defp record!(debtor, creditor, id, d, c, minor, denomination \\ "USD") do
    {:ok, [event]} =
      Log.append(
        multi_signed_event(
          [role(debtor, "debtor"), role(creditor, "creditor")],
          "ObligationRecorded",
          %{
            "obligation_id" => id,
            "debtor_id" => d,
            "creditor_id" => c,
            "amount_minor" => minor,
            "denomination" => denomination
          }
        )
      )

    event
  end

  defp pair!(ctx) do
    ab = record!(ctx.alice, ctx.bob, "OB-1", "M-alice", "M-bob", 100)
    ba = record!(ctx.bob, ctx.alice, "OB-2", "M-bob", "M-alice", 60)
    {ab, ba}
  end

  defp snapshot do
    CommercialSetoffSources.snapshot(@chapter, {"M-alice", "M-bob"}, "USD")
  end

  defp grants(ctx) do
    %{
      "M-alice" => %{
        key_id: ctx.alice.signer.key_id,
        digest: :crypto.hash(:sha256, "test-not-real-agency-a"),
        active: true
      },
      "M-bob" => %{
        key_id: ctx.bob.signer.key_id,
        digest: :crypto.hash(:sha256, "test-not-real-agency-b"),
        active: true
      }
    }
  end

  defp evidence do
    %{
      "jurisdiction" => "TEST-ONLY",
      "legal_basis_digest" => :crypto.hash(:sha256, "synthetic-law"),
      "discharge_evidence_digest" => :crypto.hash(:sha256, "synthetic-release"),
      "policy_decision_digest" => :crypto.hash(:sha256, "synthetic-policy")
    }
  end

  test "extracts signed full-record hashes and exact source versions without admitting anything", ctx do
    {ab, ba} = pair!(ctx)
    head_before = Log.head()

    assert {:ok, snapshot} = snapshot()
    assert snapshot.observed_head == head_before
    assert Log.head() == head_before
    assert snapshot.source_status == :locally_signed_business_history
    assert snapshot.agency_status == :unverified
    assert snapshot.legal_status == :unverified
    assert snapshot.admission == :not_authorized
    assert snapshot.settlement == :none
    assert Enum.map(snapshot.sources, & &1["obligation_id"]) == ["OB-1", "OB-2"]

    {:ok, hash_ab} = Envelope.event_hash(ab)
    {:ok, hash_ba} = Envelope.event_hash(ba)
    assert Enum.map(snapshot.sources, & &1["source_event_hash"]) == [hash_ab, hash_ba]
    assert Enum.map(snapshot.sources, & &1["revision"]) == [1, 1]

    assert {:ok, proof} =
             CommercialSetoffProof.prepare(
               snapshot.gate,
               @chapter,
               {"M-alice", "M-bob"},
               "USD",
               snapshot.sources,
               "PROPOSED-SET-1",
               grants(ctx),
               evidence()
             )

    assert proof.body["setoff"] == 60
    assert proof.status == :unsigned_inert_contract
    assert proof.signed_event_binding == :none
    assert Log.head() == head_before
  end

  test "a source history with assignments remains refused even if present-day parties are unchanged", ctx do
    pair!(ctx)

    {:ok, [_]} =
      Log.append(
        multi_signed_event(
          [role(ctx.alice, "assignor"), role(ctx.carol, "assignee")],
          "ObligationAssigned",
          %{"obligation_id" => "OB-1", "new_debtor_id" => "M-carol"}
        )
      )

    {:ok, [_]} =
      Log.append(
        multi_signed_event(
          [role(ctx.carol, "assignor"), role(ctx.alice, "assignee")],
          "ObligationAssigned",
          %{"obligation_id" => "OB-1", "new_debtor_id" => "M-alice"}
        )
      )

    assert {:error, {:unsupported_source_history, "OB-1"}} = snapshot()
    assert :ok = Log.verify_chains()
  end

  test "same-value substituted obligations produce different authenticated IDs/hashes", ctx do
    {_ab, _ba} = pair!(ctx)
    assert {:ok, original} = snapshot()

    {:ok, [_]} =
      Log.append(
        multi_signed_event(
          [role(ctx.bob, "debtor"), role(ctx.alice, "creditor")],
          "ObligationDischarged",
          %{"obligation_id" => "OB-2"}
        )
      )

    record!(ctx.bob, ctx.alice, "OB-3", "M-bob", "M-alice", 60)
    assert {:ok, updated} = snapshot()
    assert Enum.map(updated.sources, & &1["obligation_id"]) == ["OB-1", "OB-3"]

    refute updated.sources == original.sources

    assert {:error, :source_set_changed} =
             CommercialSetoffProof.prepare(
               updated.gate,
               @chapter,
               {"M-alice", "M-bob"},
               "USD",
               original.sources,
               "PROPOSED-SET-1",
               grants(ctx),
               evidence()
             )

    assert :ok = Log.verify_chains()
  end

  test "restarted signed log reconstructs identical evidence source list and hashes", ctx do
    pair!(ctx)
    assert {:ok, before} = snapshot()
    restart_log()
    assert {:ok, after_restart} = snapshot()
    assert after_restart.sources == before.sources
    assert :ok = Log.verify_chains()
  end

  test "refuses one-way, nonexistent, mixed-currency, or malformed requests", ctx do
    record!(ctx.alice, ctx.bob, "OB-1", "M-alice", "M-bob", 100)

    assert {:error, :no_bilateral_sources} = snapshot()
    assert {:error, :invalid_request} =
             CommercialSetoffSources.snapshot(@chapter, {"M-bob", "M-alice"}, "USD")

    record!(ctx.bob, ctx.alice, "OB-2", "M-bob", "M-alice", 60, "EUR")
    assert {:error, :no_bilateral_sources} = snapshot()
    assert :ok = Log.verify_chains()
  end
end
