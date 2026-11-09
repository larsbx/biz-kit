defmodule CoopSubstrate.CommercialSourceLineageTest do
  @moduledoc """
  Exact replayable SIGNED-CORE history, not underlying invoice proof or
  legally effective debt release. All test principals are fixture members.
  """
  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.CommercialSourceLineage, as: Lineage
  alias CoopSubstrate.Log
  alias CoopSubstrate.Protocol.Envelope

  @chapter "chapter-genesis"

  setup do
    principals =
      Map.new(["M-alice", "M-bob", "M-carol"], fn id ->
        actor = new_member("member")

        {:ok, [_]} =
          Log.append(signed_event(actor, "MemberRegistered", registration_payload(id, actor)))

        {id, actor}
      end)

    %{principals: principals}
  end

  defp role(actor, name), do: %{actor | signer: %{actor.signer | role: name}}

  defp event(ctx, id, debtor, creditor, amount, currency \\ "USD") do
    multi_signed_event(
      [
        role(ctx.principals[debtor], "debtor"),
        role(ctx.principals[creditor], "creditor")
      ],
      "ObligationRecorded",
      %{
        "obligation_id" => id,
        "debtor_id" => debtor,
        "creditor_id" => creditor,
        "amount_minor" => amount,
        "denomination" => currency
      }
    )
  end

  defp ledger_row(id), do: Log.gate().commercial_source_lineage[{@chapter, id}]

  test "origin digest equals the exact signed core and survives canonical restart", ctx do
    {:ok, [original]} = Log.append(event(ctx, "OB-1", "M-alice", "M-bob", 100))
    {:ok, signed_core} = Envelope.signing_bytes(original)
    expected = :crypto.hash(:sha256, signed_core)

    assert %{
             original_signed_core_digest: ^expected,
             latest_signed_core_digest: ^expected,
             source_revision: 1,
             original_only: true,
             source_kind: :original_attested,
             open: true,
             legal_effect: :not_verified,
             financial_settlement: :none
           } = ledger_row("OB-1")

    assert Lineage.original_only?(Log.gate(), @chapter, "OB-1")
    assert :ok = Log.verify_chains()

    restart_log()
    assert ledger_row("OB-1").original_signed_core_digest == expected
    assert Lineage.original_only?(Log.gate(), @chapter, "OB-1")
  end

  test "assignment out and back cannot reconstruct original-only source authority", ctx do
    {:ok, [_]} = Log.append(event(ctx, "OB-1", "M-alice", "M-bob", 100))
    initial = ledger_row("OB-1").original_signed_core_digest

    {:ok, [_]} =
      Log.append(
        multi_signed_event(
          [
            role(ctx.principals["M-alice"], "assignor"),
            role(ctx.principals["M-carol"], "assignee")
          ],
          "ObligationAssigned",
          %{"obligation_id" => "OB-1", "new_debtor_id" => "M-carol"}
        )
      )

    {:ok, [_]} =
      Log.append(
        multi_signed_event(
          [
            role(ctx.principals["M-carol"], "assignor"),
            role(ctx.principals["M-alice"], "assignee")
          ],
          "ObligationAssigned",
          %{"obligation_id" => "OB-1", "new_debtor_id" => "M-alice"}
        )
      )

    assert Log.gate().obligations[{@chapter, "OB-1"}].debtor_id == "M-alice"
    assert %{source_revision: 3, source_kind: :assigned, open: true, original_only: false} =
             ledger_row("OB-1")

    assert ledger_row("OB-1").original_signed_core_digest == initial
    refute ledger_row("OB-1").latest_signed_core_digest == initial
    refute Lineage.original_only?(Log.gate(), @chapter, "OB-1")

    restart_log()
    assert ledger_row("OB-1").source_revision == 3
    refute Lineage.original_only?(Log.gate(), @chapter, "OB-1")
    assert :ok = Log.verify_chains()
  end

  test "direct obligation discharge records signed lineage closure only", ctx do
    {:ok, [_]} = Log.append(event(ctx, "OB-1", "M-alice", "M-bob", 100))

    {:ok, [_]} =
      Log.append(
        multi_signed_event(
          [
            role(ctx.principals["M-alice"], "debtor"),
            role(ctx.principals["M-bob"], "creditor")
          ],
          "ObligationDischarged",
          %{"obligation_id" => "OB-1"}
        )
      )

    assert %{source_revision: 2, source_kind: :direct_discharge_attested,
             original_only: false, open: false, financial_settlement: :none} =
             ledger_row("OB-1")

    refute Lineage.original_only?(Log.gate(), @chapter, "OB-1")
    assert Log.gate().obligations[{@chapter, "OB-1"}].open == false
  end

  test "legacy bilateral netting closes its source histories and marks residual as derived", ctx do
    {:ok, [_]} = Log.append(event(ctx, "OB-1", "M-alice", "M-bob", 100))
    {:ok, [_]} = Log.append(event(ctx, "OB-2", "M-bob", "M-alice", 60))

    {:ok, [_]} =
      Log.append(
        multi_signed_event(
          [
            role(ctx.principals["M-alice"], "party_a"),
            role(ctx.principals["M-bob"], "party_b")
          ],
          "NettingExecuted",
          %{
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
      )

    assert %{source_revision: 2, source_kind: :legacy_netting_closed,
             original_only: false, open: false} = ledger_row("OB-1")

    assert %{source_revision: 2, source_kind: :legacy_netting_closed,
             original_only: false, open: false} = ledger_row("OB-2")

    assert %{source_revision: 1, source_kind: :legacy_netting_residual,
             original_signed_core_digest: nil, original_only: false,
             open: true, financial_settlement: :none} = ledger_row("OB-NET-1")

    assert Log.gate().obligations[{@chapter, "OB-NET-1"}].amount_minor == 40
    refute Lineage.original_only?(Log.gate(), @chapter, "OB-NET-1")

    before = Log.gate().commercial_source_lineage
    restart_log()
    assert before == Log.gate().commercial_source_lineage
    assert :ok = Log.verify_chains()
  end
end
