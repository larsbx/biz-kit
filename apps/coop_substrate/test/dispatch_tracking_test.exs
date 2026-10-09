defmodule CoopSubstrate.DispatchTrackingTest do
  @moduledoc """
  Phase 8B (docs/phase8b_plan.md): loads descend only from accepted
  tenders; the per-stop lifecycle is an unbroken, ordered sequence enforced
  at the gate; dwell is a fold over signed payload times; and check-call
  machinery is structurally absent (10 §4.1: deleted, not automated).
  """

  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.Dispatch
  alias CoopSubstrate.Harness.Artifacts
  alias CoopSubstrate.Log
  alias CoopSubstrate.Protocol.TypeRegistry
  alias CoopSubstrate.Sim.GateD

  @t0 1_752_000_000_000

  setup do
    ctx = GateD.run()

    # An accepted tender to dispatch against (the 8A rail).
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

    raw = "lane: detroit->chicago\nrate_minor: 210000\nequipment: dry_van"
    {:ok, raw_ref} = Artifacts.put(raw)

    tender = fn type, payload ->
      base = %{"member_id" => ctx.member_id, "entity_id" => ctx.entity_id}
      signed_event(ctx.steward, type, Map.merge(base, payload), chapter_id: ctx.chapter_id)
    end

    {:ok, _} =
      Log.append(tender.("TenderReceived", %{"tender_id" => "T-1", "raw_ref" => {:bytes, raw_ref}}))

    {:ok, fields} = Dispatch.Parser.parse(raw)

    {:ok, _} =
      Log.append(
        tender.("TenderParsed", %{
          "tender_id" => "T-1",
          "raw_ref" => {:bytes, raw_ref},
          "grade" => "human",
          "fields" => fields
        })
      )

    {:ok, {:accept, 1, basis}} = Dispatch.route(ctx.chapter_id, "T-1")

    {:ok, _} =
      Log.append(
        tender.("TenderAccepted", %{"tender_id" => "T-1", "envelope_version" => 1, "basis" => basis})
      )

    # A second tender left undecided, for the descent test.
    {:ok, _} =
      Log.append(tender.("TenderReceived", %{"tender_id" => "T-2", "raw_ref" => {:bytes, raw_ref}}))

    {:ok, Map.put(ctx, :event, tender)}
  end

  defp load_event(ctx, type, payload) do
    ctx.event.(type, Map.merge(%{"load_id" => "L-1"}, payload))
  end

  test "loads descend from accepted tenders only, one load per tender", ctx do
    assert {:error, {:reject, _, {:tender_not_accepted, nil}}} =
             Log.append(load_event(ctx, "LoadDispatched", %{"tender_id" => "T-2"}))

    assert {:error, {:reject, _, {:unknown_tender, "T-9"}}} =
             Log.append(load_event(ctx, "LoadDispatched", %{"tender_id" => "T-9"}))

    {:ok, _} = Log.append(load_event(ctx, "LoadDispatched", %{"tender_id" => "T-1"}))

    assert {:error, {:reject, _, {:tender_already_dispatched, "L-1"}}} =
             Log.append(ctx.event.("LoadDispatched", %{"load_id" => "L-2", "tender_id" => "T-1"}))
  end

  test "the per-stop lifecycle is an unbroken ordered sequence; dwell is a fold", ctx do
    {:ok, _} = Log.append(load_event(ctx, "LoadDispatched", %{"tender_id" => "T-1"}))

    # Departure before arrival, arrival at an unknown stop: unrepresentable.
    assert {:error, {:reject, _, :not_arrived}} =
             Log.append(
               load_event(ctx, "LoadDeparted", %{"stop" => "pickup", "occurred_ms" => @t0})
             )

    assert {:error, {:reject, _, {:unknown_stop, "yard"}}} =
             Log.append(load_event(ctx, "LoadArrived", %{"stop" => "yard", "occurred_ms" => @t0}))

    # Appointments reschedule freely until arrival, then freeze.
    for appointment <- [@t0, @t0 + 3_600_000] do
      {:ok, _} =
        Log.append(
          load_event(ctx, "AppointmentRecorded", %{
            "stop" => "pickup",
            "appointment_ms" => appointment
          })
        )
    end

    {:ok, _} =
      Log.append(
        load_event(ctx, "LoadArrived", %{"stop" => "pickup", "occurred_ms" => @t0 + 3_600_000})
      )

    assert {:error, {:reject, _, :already_arrived}} =
             Log.append(
               load_event(ctx, "AppointmentRecorded", %{"stop" => "pickup", "appointment_ms" => @t0})
             )

    assert {:error, {:reject, _, :already_arrived}} =
             Log.append(
               load_event(ctx, "LoadArrived", %{"stop" => "pickup", "occurred_ms" => @t0})
             )

    # Time cannot run backwards across a stop.
    assert {:error, {:reject, _, :departure_before_arrival}} =
             Log.append(
               load_event(ctx, "LoadDeparted", %{"stop" => "pickup", "occurred_ms" => @t0})
             )

    {:ok, _} =
      Log.append(
        load_event(ctx, "LoadDeparted", %{"stop" => "pickup", "occurred_ms" => @t0 + 9_000_000})
      )

    assert {:error, {:reject, _, :already_departed}} =
             Log.append(
               load_event(ctx, "LoadDeparted", %{"stop" => "pickup", "occurred_ms" => @t0 + 9_999_000})
             )

    # Status trail is import-shaped and free of ordering ceremony.
    {:ok, _} =
      Log.append(
        load_event(ctx, "StatusRecorded", %{"status" => "in_transit", "occurred_ms" => @t0 + 10_000_000})
      )

    assert {:error, {:reject, _, :empty_status}} =
             Log.append(
               load_event(ctx, "StatusRecorded", %{"status" => "", "occurred_ms" => @t0})
             )

    # Delivery leg, then the dwell fold: (departed − arrived) minutes.
    {:ok, _} =
      Log.append(
        load_event(ctx, "AppointmentRecorded", %{"stop" => "delivery", "appointment_ms" => @t0 + 20_000_000})
      )

    {:ok, _} =
      Log.append(
        load_event(ctx, "LoadArrived", %{"stop" => "delivery", "occurred_ms" => @t0 + 21_000_000})
      )

    {:ok, _} =
      Log.append(
        load_event(ctx, "LoadDeparted", %{"stop" => "delivery", "occurred_ms" => @t0 + 28_200_000})
      )

    assert {:ok, dwell} = Dispatch.dwell(ctx.chapter_id, "L-1")

    assert dwell == %{
             "pickup" => %{
               appointment_ms: @t0 + 3_600_000,
               arrived_ms: @t0 + 3_600_000,
               departed_ms: @t0 + 9_000_000,
               dwell_minutes: 90
             },
             "delivery" => %{
               appointment_ms: @t0 + 20_000_000,
               arrived_ms: @t0 + 21_000_000,
               departed_ms: @t0 + 28_200_000,
               dwell_minutes: 120
             }
           }

    assert :ok = Log.verify_chains()
  end

  test "no check-call machinery exists (10 §4.1: deleted, not automated)" do
    for type <- ["CheckCallScheduled", "CheckCallRecorded", "CheckCallDue"] do
      refute TypeRegistry.registered?(type)
    end

    refute Code.ensure_loaded?(CoopSubstrate.Dispatch.CheckCalls)
  end
end
