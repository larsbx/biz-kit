defmodule CoopSubstrate.DispatchDemoTest do
  @moduledoc """
  Phase 8D (docs/phase8d_plan.md): every demo number recompiles from the
  carrier's full stream (selective compilation unrepresentable by shape);
  minutes-returned fails closed while its charter constant is undeclared;
  ε(π) is a surfaced counter, never an estimate. Sim world only — these
  numbers are a rehearsal of the folds, not campaign assets.
  """

  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.Dispatch
  alias CoopSubstrate.Harness.Artifacts
  alias CoopSubstrate.Log
  alias CoopSubstrate.Sim.GateD

  @t0 1_752_000_000_000
  @minute 60_000

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

    {:ok, _} =
      event.(ctx.carrier, "RateTermsDeclared", %{
        "version" => 1,
        "params" => %{
          "free_time_minutes" => 120,
          "detention_rate_minor_per_hour" => 6_000,
          "dunning_rungs" => ["reminder"]
        }
      })

    # Two tenders: one accepted → dispatched → completed → invoiced, one
    # declined (below floor). One out-of-envelope escalation on the R rail.
    accept_raw = "lane: detroit->chicago\nrate_minor: 210000\nequipment: dry_van"
    decline_raw = "lane: detroit->chicago\nrate_minor: 90000\nequipment: dry_van"

    for {id, raw} <- [{"T-1", accept_raw}, {"T-2", decline_raw}] do
      {:ok, ref} = Artifacts.put(raw)
      {:ok, fields} = Dispatch.Parser.parse(raw)
      {:ok, _} = event.(ctx.steward, "TenderReceived", %{"tender_id" => id, "raw_ref" => {:bytes, ref}})

      {:ok, _} =
        event.(ctx.steward, "TenderParsed", %{
          "tender_id" => id,
          "raw_ref" => {:bytes, ref},
          "grade" => "human",
          "fields" => fields
        })
    end

    {:ok, {:accept, 1, accept_basis}} = Dispatch.route(ctx.chapter_id, "T-1")
    {:ok, {:decline, 1, decline_basis}} = Dispatch.route(ctx.chapter_id, "T-2")

    {:ok, _} =
      event.(ctx.steward, "TenderAccepted", %{
        "tender_id" => "T-1",
        "envelope_version" => 1,
        "basis" => accept_basis
      })

    {:ok, _} =
      event.(ctx.steward, "TenderDeclined", %{
        "tender_id" => "T-2",
        "envelope_version" => 1,
        "basis" => decline_basis
      })

    {:ok, escalation_ref} = Artifacts.put("off-lane ask")

    {:ok, _} =
      Log.append(
        signed_event(
          ctx.steward,
          "EscalationRaised",
          %{
            "item_id" => "tender/T-offlane",
            "process" => "tender_accept",
            "act_type" => "tender_decision",
            "packet_refs" => [Base.encode16(escalation_ref, case: :lower)],
            "recommendation" => "call back",
            "bounds" => %{},
            "compensation_path" => "decline after the call",
            "deadline_ms" => 4_102_444_800_000,
            "basis_ref" => {:bytes, escalation_ref}
          },
          chapter_id: ctx.chapter_id
        )
      )

    {:ok, _} = event.(ctx.steward, "LoadDispatched", %{"load_id" => "L-1", "tender_id" => "T-1"})

    for {type, payload} <- [
          {"AppointmentRecorded", %{"stop" => "pickup", "appointment_ms" => @t0}},
          {"LoadArrived", %{"stop" => "pickup", "occurred_ms" => @t0}},
          {"StatusRecorded", %{"status" => "loaded", "occurred_ms" => @t0 + 10 * @minute}},
          {"LoadDeparted", %{"stop" => "pickup", "occurred_ms" => @t0 + 200 * @minute}},
          {"StatusRecorded", %{"status" => "in_transit", "occurred_ms" => @t0 + 300 * @minute}},
          {"LoadArrived", %{"stop" => "delivery", "occurred_ms" => @t0 + 500 * @minute}},
          {"LoadDeparted", %{"stop" => "delivery", "occurred_ms" => @t0 + 560 * @minute}},
          {"StatusRecorded", %{"status" => "delivered", "occurred_ms" => @t0 + 560 * @minute}}
        ] do
      {:ok, _} = event.(ctx.steward, type, Map.put(payload, "load_id", "L-1"))
    end

    {:ok, computed} = Dispatch.compute_invoice(ctx.chapter_id, "L-1")

    {:ok, _} =
      event.(ctx.steward, "InvoiceIssued", %{
        "invoice_id" => "INV-1",
        "load_id" => "L-1",
        "terms_version" => computed.terms_version,
        "lines" => computed.lines,
        "amount_minor" => computed.amount_minor
      })

    {:ok, _} =
      event.(ctx.steward, "CreditMemoIssued", %{
        "memo_id" => "CM-1",
        "invoice_id" => "INV-1",
        "amount_minor" => 3_000,
        "reason" => "goodwill"
      })

    {:ok, Map.put(ctx, :event, event)}
  end

  test "every demo number recompiles from the full stream; minutes-returned fails closed", ctx do
    {:ok, kit} = Dispatch.demo_kit(ctx.chapter_id, ctx.member_id, ctx.entity_id)

    assert kit == %{
             tenders: %{received: 2, accepted: 1, declined: 1, undecided: 0},
             loads: %{dispatched: 1, completed: 1},
             open_book: %{invoiced_minor: 218_000, credited_minor: 3_000, net_minor: 215_000},
             detention: %{minutes: 80, invoiced_minor: 8_000},
             check_calls: %{statuses_ingested: 3, minutes_returned: nil}
           }

    # Declaring the constant turns the count into minutes — nothing else moves.
    author = new_member("author")

    {:ok, _} =
      Log.append(
        signed_event(
          author,
          "CharterConstantDeclared",
          %{"name" => "dispatch/minutes_per_check_call", "value" => 15},
          chapter_id: ctx.chapter_id
        )
      )

    {:ok, declared} = Dispatch.demo_kit(ctx.chapter_id, ctx.member_id, ctx.entity_id)
    assert declared.check_calls == %{statuses_ingested: 3, minutes_returned: 45}
    assert %{declared | check_calls: kit.check_calls} == kit

    # Recompile-and-compare across an appender restart (§0.8 discipline).
    restart_log()
    assert {:ok, ^declared} = Dispatch.demo_kit(ctx.chapter_id, ctx.member_id, ctx.entity_id)

    # Another member's demo kit sees none of this carrier's exhaust.
    assert {:ok, empty} = Dispatch.demo_kit(ctx.chapter_id, "M-other", ctx.entity_id)
    assert empty.tenders.received == 0
    assert empty.open_book.invoiced_minor == 0
  end

  test "ε(π) is computable per process — counters surfaced, nothing estimated", ctx do
    {:ok, guards} = Dispatch.guards(ctx.chapter_id)

    # 2 decisions + 1 escalation on tender_accept: ε = 1/3 in basis points.
    assert guards == %{
             "tender_accept" => %{decisions: 2, escalations: 1, epsilon_bp: 3_333}
           }
  end
end
