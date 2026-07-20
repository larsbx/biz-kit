defmodule CoopSubstrate.DispatchInvoiceTest do
  @moduledoc """
  Phase 8C (docs/phase8c_plan.md): rate terms are versioned member-signed
  events; the invoice is gate-recomputed from custody events + terms (a
  differing invoice is unrepresentable); credit memos compensate without
  overshooting; dunning walks the declared rungs exactly and collection
  is reachable only through every rung.
  """

  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.Dispatch
  alias CoopSubstrate.Export
  alias CoopSubstrate.Harness.Artifacts
  alias CoopSubstrate.Log
  alias CoopSubstrate.Sim.GateD

  @t0 1_752_000_000_000
  @minute 60_000

  setup do
    ctx = GateD.run()

    {:ok, _} =
      Log.append(
        signed_event(
          ctx.carrier,
          "EnvelopeDeclared",
          %{
            "member_id" => ctx.member_id,
            "entity_id" => ctx.entity_id,
            "scope" => "tender_accept",
            "version" => 1,
            "params" => %{
              "lanes" => ["detroit->chicago"],
              "equipment" => ["dry_van"],
              "rate_floor_minor" => 150_000
            }
          },
          chapter_id: ctx.chapter_id
        )
      )

    event = fn actor, type, payload ->
      base = %{"member_id" => ctx.member_id, "entity_id" => ctx.entity_id}
      Log.append(signed_event(actor, type, Map.merge(base, payload), chapter_id: ctx.chapter_id))
    end

    raw = "lane: detroit->chicago\nrate_minor: 210000\nequipment: dry_van"
    {:ok, raw_ref} = Artifacts.put(raw)
    {:ok, fields} = Dispatch.Parser.parse(raw)

    {:ok, _} =
      event.(ctx.steward, "TenderReceived", %{
        "tender_id" => "T-1",
        "raw_ref" => {:bytes, raw_ref}
      })

    {:ok, _} =
      event.(ctx.steward, "TenderParsed", %{
        "tender_id" => "T-1",
        "raw_ref" => {:bytes, raw_ref},
        "grade" => "human",
        "fields" => fields
      })

    {:ok, {:accept, 1, basis}} = Dispatch.route(ctx.chapter_id, "T-1")

    {:ok, _} =
      event.(ctx.steward, "TenderAccepted", %{
        "tender_id" => "T-1",
        "envelope_version" => 1,
        "basis" => basis
      })

    {:ok, _} = event.(ctx.steward, "LoadDispatched", %{"load_id" => "L-1", "tender_id" => "T-1"})

    {:ok, Map.put(ctx, :event, event)}
  end

  defp declare_terms!(ctx, version, overrides \\ %{}) do
    ctx.event.(ctx.carrier, "RateTermsDeclared", %{
      "version" => version,
      "params" =>
        Map.merge(
          %{
            "free_time_minutes" => 120,
            "detention_rate_minor_per_hour" => 6_000,
            "dunning_rungs" => ["reminder", "final_notice"]
          },
          overrides
        )
    })
  end

  # Pickup dwells 200' against a 120' free window (80' detention); delivery
  # dwells inside free time. Detention counts from max(arrived, appointment).
  defp run_load!(ctx) do
    for {type, payload} <- [
          {"AppointmentRecorded", %{"stop" => "pickup", "appointment_ms" => @t0}},
          {"LoadArrived", %{"stop" => "pickup", "occurred_ms" => @t0}},
          {"LoadDeparted", %{"stop" => "pickup", "occurred_ms" => @t0 + 200 * @minute}},
          {"LoadArrived", %{"stop" => "delivery", "occurred_ms" => @t0 + 500 * @minute}},
          {"LoadDeparted", %{"stop" => "delivery", "occurred_ms" => @t0 + 560 * @minute}}
        ] do
      {:ok, _} = ctx.event.(ctx.steward, type, Map.put(payload, "load_id", "L-1"))
    end
  end

  defp invoice_payload(computed) do
    %{
      "invoice_id" => "INV-1",
      "load_id" => "L-1",
      "terms_version" => computed.terms_version,
      "lines" => computed.lines,
      "amount_minor" => computed.amount_minor
    }
  end

  test "terms follow the envelope discipline: member-signed, exact params, monotonic", ctx do
    attacker = new_member("member")

    assert {:error, {:reject, _, {:not_the_members_current_key, _}}} =
             Log.append(
               signed_event(
                 attacker,
                 "RateTermsDeclared",
                 %{
                   "member_id" => ctx.member_id,
                   "entity_id" => ctx.entity_id,
                   "version" => 1,
                   "params" => %{
                     "free_time_minutes" => 120,
                     "detention_rate_minor_per_hour" => 6_000,
                     "dunning_rungs" => ["reminder"]
                   }
                 },
                 chapter_id: ctx.chapter_id
               )
             )

    assert {:error, {:reject, _, :malformed_terms_params}} =
             declare_terms!(ctx, 1, %{"dunning_rungs" => []})

    assert {:error, {:reject, _, {:terms_version_not_monotonic, 2}}} = declare_terms!(ctx, 2)

    {:ok, _} = declare_terms!(ctx, 1)
    {:ok, _} = declare_terms!(ctx, 2, %{"free_time_minutes" => 90})
  end

  test "the invoice is unrepresentable while the custody chain is incomplete", ctx do
    {:ok, _} = declare_terms!(ctx, 1)

    assert {:error, :load_incomplete} = Dispatch.compute_invoice(ctx.chapter_id, "L-1")

    assert {:error, {:reject, _, {:invoice_not_computable, :load_incomplete}}} =
             Log.append(
               signed_event(
                 ctx.steward,
                 "InvoiceIssued",
                 %{
                   "invoice_id" => "INV-1",
                   "load_id" => "L-1",
                   "member_id" => ctx.member_id,
                   "entity_id" => ctx.entity_id,
                   "terms_version" => 1,
                   "lines" => [],
                   "amount_minor" => 0
                 },
                 chapter_id: ctx.chapter_id
               )
             )
  end

  test "invoice recompute, tamper rejection, compensator bounds, dunning ladder", ctx do
    {:ok, _} = declare_terms!(ctx, 1)
    run_load!(ctx)

    assert {:ok, computed} = Dispatch.compute_invoice(ctx.chapter_id, "L-1")

    assert computed == %{
             terms_version: 1,
             lines: [
               %{"kind" => "linehaul", "amount_minor" => 210_000},
               %{
                 "kind" => "detention",
                 "stop" => "pickup",
                 "minutes" => 80,
                 "amount_minor" => 8_000
               }
             ],
             amount_minor: 218_000
           }

    # A tampered total or a stale terms version never lands.
    tampered = invoice_payload(%{computed | amount_minor: 219_000})

    assert {:error, {:reject, _, :invoice_mismatch}} =
             Log.append(
               signed_event(
                 ctx.steward,
                 "InvoiceIssued",
                 Map.merge(
                   %{"member_id" => ctx.member_id, "entity_id" => ctx.entity_id},
                   tampered
                 ), chapter_id: ctx.chapter_id)
             )

    {:ok, _} = ctx.event.(ctx.steward, "InvoiceIssued", invoice_payload(computed))

    assert {:error, {:reject, _, {:load_already_invoiced, "INV-1"}}} =
             Log.append(
               signed_event(
                 ctx.steward,
                 "InvoiceIssued",
                 Map.merge(
                   %{"member_id" => ctx.member_id, "entity_id" => ctx.entity_id},
                   %{invoice_payload(computed) | "invoice_id" => "INV-2"}
                 ), chapter_id: ctx.chapter_id)
             )

    # Compensator: reverses value, never overshoots, memo ids unique.
    {:ok, _} =
      ctx.event.(ctx.steward, "CreditMemoIssued", %{
        "memo_id" => "CM-1",
        "invoice_id" => "INV-1",
        "amount_minor" => 8_000,
        "reason" => "detention waived on appeal"
      })

    assert {:error, {:reject, _, {:memo_already_issued, "CM-1"}}} =
             Log.append(
               signed_event(
                 ctx.steward,
                 "CreditMemoIssued",
                 %{
                   "memo_id" => "CM-1",
                   "invoice_id" => "INV-1",
                   "member_id" => ctx.member_id,
                   "entity_id" => ctx.entity_id,
                   "amount_minor" => 1,
                   "reason" => "dup"
                 }, chapter_id: ctx.chapter_id)
             )

    assert {:error, {:reject, _, :credit_exceeds_invoice}} =
             Log.append(
               signed_event(
                 ctx.steward,
                 "CreditMemoIssued",
                 %{
                   "memo_id" => "CM-2",
                   "invoice_id" => "INV-1",
                   "member_id" => ctx.member_id,
                   "entity_id" => ctx.entity_id,
                   "amount_minor" => 210_001,
                   "reason" => "overshoot"
                 }, chapter_id: ctx.chapter_id)
             )

    # Dunning: the declared rungs, in order, exactly once, then R.
    step = fn index, rung ->
      Log.append(
        signed_event(
          ctx.steward,
          "DunningStepped",
          %{
            "invoice_id" => "INV-1",
            "member_id" => ctx.member_id,
            "entity_id" => ctx.entity_id,
            "rung_index" => index,
            "rung" => rung
          }, chapter_id: ctx.chapter_id)
      )
    end

    escalate = fn ->
      Log.append(
        signed_event(
          ctx.steward,
          "CollectionEscalated",
          %{"invoice_id" => "INV-1", "member_id" => ctx.member_id, "entity_id" => ctx.entity_id},
          chapter_id: ctx.chapter_id
        )
      )
    end

    assert {:error, {:reject, _, {:ladder_not_exhausted, 0, 2}}} = escalate.()
    assert {:error, {:reject, _, {:rung_out_of_order, 1, 0}}} = step.(1, "final_notice")

    assert {:error, {:reject, _, {:rung_mismatch, "final_notice", "reminder"}}} =
             step.(0, "final_notice")

    {:ok, _} = step.(0, "reminder")
    {:ok, _} = step.(1, "final_notice")
    assert {:error, {:reject, _, :ladder_exhausted}} = step.(2, "again")

    {:ok, _} = escalate.()
    assert {:error, {:reject, _, :in_collection}} = escalate.()
    assert {:error, {:reject, _, :in_collection}} = step.(2, "reminder")

    # The carrier's whole invoicing trail rides the departure bundle.
    {:ok, bundle} = Export.member_bundle(ctx.chapter_id, ctx.member_id)

    assert Map.has_key?(
             bundle.streams,
             "#{ctx.chapter_id}/terms/#{ctx.member_id}/#{ctx.entity_id}"
           )

    assert Map.has_key?(
             bundle.streams,
             "#{ctx.chapter_id}/invoices/#{ctx.member_id}/#{ctx.entity_id}"
           )

    assert {:ok, _} = Export.verify(bundle)
    assert :ok = Log.verify_chains()
  end

  test "dunning is frozen at the invoice's terms version, not the member's latest", ctx do
    {:ok, _} = declare_terms!(ctx, 1)
    run_load!(ctx)

    {:ok, computed} = Dispatch.compute_invoice(ctx.chapter_id, "L-1")
    {:ok, _} = ctx.event.(ctx.steward, "InvoiceIssued", invoice_payload(computed))

    # New terms with a different ladder — the issued invoice keeps its own.
    {:ok, _} = declare_terms!(ctx, 2, %{"dunning_rungs" => ["one_giant_rung"]})

    assert {:error, {:reject, _, {:rung_mismatch, "one_giant_rung", "reminder"}}} =
             Log.append(
               signed_event(
                 ctx.steward,
                 "DunningStepped",
                 %{
                   "invoice_id" => "INV-1",
                   "member_id" => ctx.member_id,
                   "entity_id" => ctx.entity_id,
                   "rung_index" => 0,
                   "rung" => "one_giant_rung"
                 }, chapter_id: ctx.chapter_id)
             )
  end
end
