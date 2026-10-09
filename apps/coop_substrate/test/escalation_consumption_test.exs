defmodule CoopSubstrate.EscalationConsumptionTest do
  @moduledoc """
  Phase 9B (docs/phase9b_plan.md): an approved `tender/<id>` R item
  authorizes exactly one decision event on that tender — structurally
  referenced, marked as human-authorized (envelope_version 0, basis
  "r/<item>") — and only where the pure decision still says escalate.
  Everything else about 8A routing stays exactly as it was.
  """

  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.Dispatch
  alias CoopSubstrate.Harness.Artifacts
  alias CoopSubstrate.Log
  alias CoopSubstrate.Sim.GateD

  setup do
    ctx = GateD.run()

    event = fn actor, type, payload ->
      base = %{"member_id" => ctx.member_id, "entity_id" => ctx.entity_id}
      Log.append(signed_event(actor, type, Map.merge(base, payload), chapter_id: ctx.chapter_id))
    end

    {:ok, _} =
      event.(ctx.carrier, "EnvelopeDeclared", %{
        "scope" => "tender_accept",
        "version" => 1,
        "params" => %{
          "lanes" => ["detroit->chicago"],
          "equipment" => ["dry_van"],
          "rate_floor_minor" => 150_000
        }
      })

    # An off-lane tender: the pure function can only escalate.
    raw = "lane: miami->atlanta\nrate_minor: 250000\nequipment: reefer"
    {:ok, raw_ref} = Artifacts.put(raw)
    {:ok, fields} = Dispatch.Parser.parse(raw)

    {:ok, _} =
      event.(ctx.steward, "TenderReceived", %{"tender_id" => "T-1", "raw_ref" => {:bytes, raw_ref}})

    {:ok, _} =
      event.(ctx.steward, "TenderParsed", %{
        "tender_id" => "T-1",
        "raw_ref" => {:bytes, raw_ref},
        "grade" => "human",
        "fields" => fields
      })

    {:ok, {:escalate, {:out_of_envelope, :lane}}} = Dispatch.route(ctx.chapter_id, "T-1")

    raise_item = fn tender_id ->
      Log.append(
        signed_event(
          ctx.steward,
          "EscalationRaised",
          %{
            "item_id" => "tender/" <> tender_id,
            "process" => "tender_accept",
            "act_type" => "tender_decision",
            "packet_refs" => [Base.encode16(raw_ref, case: :lower)],
            "recommendation" => "operator judgment on the off-lane ask",
            "bounds" => %{"scope" => "tender_accept"},
            "compensation_path" => "decline after the call",
            "deadline_ms" => 4_102_444_800_000,
            "basis_ref" => {:bytes, raw_ref}
          },
          chapter_id: ctx.chapter_id
        )
      )
    end

    resolve = fn tender_id, verdict ->
      Log.append(
        signed_event(
          ctx.steward,
          "EscalationResolved",
          %{"item_id" => "tender/" <> tender_id, "verdict" => verdict},
          chapter_id: ctx.chapter_id
        )
      )
    end

    decision = fn type, tender_id, payload ->
      event.(
        ctx.steward,
        type,
        Map.merge(
          %{
            "tender_id" => tender_id,
            "envelope_version" => 0,
            "basis" => "r/tender/" <> tender_id,
            "authorization_item_id" => "tender/" <> tender_id
          },
          payload
        )
      )
    end

    {:ok,
     Map.merge(ctx, %{event: event, raise_item: raise_item, resolve: resolve, decision: decision})}
  end

  test "an approved item authorizes exactly one marked decision", ctx do
    # 8A regression: unauthorized routes stay unrepresentable.
    assert {:error, {:reject, _, {:decision_requires_escalation, {:out_of_envelope, :lane}}}} =
             ctx.event.(ctx.steward, "TenderAccepted", %{
               "tender_id" => "T-1",
               "envelope_version" => 1,
               "basis" => "manual"
             })

    # An authorization must exist, be resolved, and be approved.
    assert {:error, {:reject, _, {:unknown_item, "tender/T-1"}}} =
             ctx.decision.("TenderAccepted", "T-1", %{})

    {:ok, _} = ctx.raise_item.("T-1")

    assert {:error, {:reject, _, {:item_unresolved, "tender/T-1"}}} =
             ctx.decision.("TenderAccepted", "T-1", %{})

    {:ok, _} = ctx.resolve.("T-1", "approved")

    # The marking is exact: version 0 and basis "r/<item>" — anything else
    # is a masquerade and dies.
    assert {:error, {:reject, _, :authorized_decision_marking_mismatch}} =
             ctx.decision.("TenderAccepted", "T-1", %{"envelope_version" => 1})

    assert {:error, {:reject, _, :authorized_decision_marking_mismatch}} =
             ctx.decision.("TenderAccepted", "T-1", %{"basis" => "operator said yes"})

    assert {:error, {:reject, _, {:authorization_subject_mismatch, "tender/T-9"}}} =
             ctx.decision.("TenderAccepted", "T-1", %{"authorization_item_id" => "tender/T-9"})

    {:ok, _} = ctx.decision.("TenderAccepted", "T-1", %{})

    # Consumed: the tender is decided; the approval authorizes nothing more.
    assert {:error, {:reject, _, {:tender_already_decided, :accepted}}} =
             ctx.decision.("TenderDeclined", "T-1", %{})

    # Downstream is normal: the authorized accept dispatches like any other.
    {:ok, _} =
      ctx.event.(ctx.steward, "LoadDispatched", %{"load_id" => "L-1", "tender_id" => "T-1"})

    assert :ok = Log.verify_chains()
  end

  test "declined and returned verdicts authorize nothing", ctx do
    {:ok, _} = ctx.raise_item.("T-1")
    {:ok, _} = ctx.resolve.("T-1", "declined")

    assert {:error, {:reject, _, {:not_authorized, "declined"}}} =
             ctx.decision.("TenderAccepted", "T-1", %{})

    assert {:error, {:reject, _, {:not_authorized, "declined"}}} =
             ctx.decision.("TenderDeclined", "T-1", %{})
  end

  test "a decidable tender never wears an authorization", ctx do
    # An in-envelope tender: the pure function decides, so the authorized
    # path is closed even with a plausible-looking item id.
    raw = "lane: detroit->chicago\nrate_minor: 210000\nequipment: dry_van"
    {:ok, raw_ref} = Artifacts.put(raw)
    {:ok, fields} = Dispatch.Parser.parse(raw)

    {:ok, _} =
      ctx.event.(ctx.steward, "TenderReceived", %{"tender_id" => "T-2", "raw_ref" => {:bytes, raw_ref}})

    {:ok, _} =
      ctx.event.(ctx.steward, "TenderParsed", %{
        "tender_id" => "T-2",
        "raw_ref" => {:bytes, raw_ref},
        "grade" => "human",
        "fields" => fields
      })

    assert {:ok, {:accept, 1, basis}} = Dispatch.route(ctx.chapter_id, "T-2")

    assert {:error, {:reject, _, :authorization_not_needed}} =
             ctx.decision.("TenderAccepted", "T-2", %{})

    {:ok, _} =
      ctx.event.(ctx.steward, "TenderAccepted", %{
        "tender_id" => "T-2",
        "envelope_version" => 1,
        "basis" => basis
      })
  end
end
