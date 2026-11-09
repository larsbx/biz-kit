defmodule CoopSubstrate.ProcurementTest do
  use CoopSubstrate.LogCase, async: false
  alias CoopSubstrate.{Log, Procurement, ProcurementDispatch, ProcurementFixture, ProcurementTestClock}
  alias CoopSubstrate.Projections.AdmissionGate
  alias CoopSubstrate.Protocol.Envelope
  alias ProcurementFixture, as: F
  setup do
    {:ok, f: F.setup()}
  end

  @tenant "11111111-1111-1111-1111-111111111111"
  @load "22222222-2222-2222-2222-222222222222"
  @assignment "33333333-3333-3333-3333-333333333333"
  @pickup "44444444-4444-4444-4444-444444444444"
  @dropoff "55555555-5555-5555-5555-555555555555"
  @pick_digest String.duplicate("a", 64)
  @drop_digest String.duplicate("b", 64)

  test "two valid signatures cannot interrupt or mutate the canonical appender", %{f: f} do
    :ok = F.quoted(f)
    assert {:ok, _} = F.submit(f, "accept", 3, F.acceptance())
    enrolled = new_member("procurement_dispatch", "dispatch-key")
    assert {:ok, [_]} = Log.append(route(f, enrolled, true, 0))
    :ok = Procurement.request_dispatch(f.context, "request-1", 4, @pick_digest, @drop_digest)

    first_rogue = new_member("procurement_dispatch", "rogue-1")
    second_rogue = new_member("procurement_dispatch", "rogue-2")
    valid = step(f, enrolled, "accept", 0)
    appender = GenServer.whereis(Log.server())
    head = Log.head()
    gate = Log.gate()
    assert {:ok, events} = Log.read_all()

    for signers <- [[first_rogue, second_rogue], [enrolled, first_rogue]] do
      attack =
        multi_signed_event(signers, valid.type, valid.payload,
          chapter_id: valid.chapter_id,
          timestamp_ms: valid.timestamp_ms
        )

      assert :ok = Envelope.verify(attack)
      assert {:error, {:reject, 0, :procurement_dispatch_forbidden}} = Log.append(attack)
      assert GenServer.whereis(Log.server()) == appender
      assert Log.head() == head
      assert Log.gate() == gate
      assert Log.read_all() == {:ok, events}
    end

    assert {:ok, [committed]} = Log.append(valid)
    assert committed.global_seq == head.global_seq + 1
    assert GenServer.whereis(Log.server()) == appender
    assert :ok = Log.verify_chains()
  end

  test "Dispatch closes the existing order with exact signed custody evidence and replays", %{f: f} do
    :ok = F.quoted(f)
    {:ok, _} = F.submit(f, "accept", 3, F.acceptance())
    courier = new_member("procurement_dispatch", "dispatch-key")
    {:ok, [_]} = Log.append(route(f, courier, true, 0))

    assert {:error, {:reject, 0, :stale_version}} =
             Procurement.request_dispatch(f.context, "request-1", 3, @pick_digest, @drop_digest)
    assert :ok = Procurement.request_dispatch(f.context, "request-1", 4, @pick_digest, @drop_digest)
    assert {:error, {:reject, 0, :dispatch_handoff_in_progress}} =
             F.submit(f, "fulfill", 5, %{"evidence_ref" => "manual"})

    initial = Procurement.state(Log.gate())
    assert [%{order_id: "request-1", phase: "requested"}] =
             ProcurementDispatch.work(initial, f.context.chapter_id, "coop", @tenant, "")
    assert [] = ProcurementDispatch.work(initial, f.context.chapter_id, "other", @tenant, "")

    rogue = new_member("procurement_dispatch", "dispatch-key")
    assert {:error, {:reject, 0, :procurement_dispatch_forbidden}} =
             Log.append(step(f, rogue, "accept", 0))
    assert {:ok, [_]} = Log.append(step(f, courier, "accept", 0))
    assert {:error, {:reject, 0, :dispatch_custody_reconciliation_required}} =
             F.submit(f, "cancel", 5, %{"evidence_ref" => "cancel"})

    dropoff = %{"proof_id" => @dropoff, "proof_digest" => @drop_digest}
    assert {:error, _} = Log.append(step(f, courier, "delivered", 1, dropoff))
    assert {:error, {:reject, 0, :delivery_code_required_or_invalid}} =
             Log.append(step(f, courier, "picked_up", 1, %{"proof_id" => @pickup, "proof_digest" => @drop_digest}))

    assert {:ok, [_]} =
             Log.append(step(f, courier, "picked_up", 1, %{"proof_id" => @pickup, "proof_digest" => @pick_digest}))

    # Separate evidence may advance the commerce version while transport is underway.
    assert {:ok, _} = F.submit(f, "payment_evidence", 5, %{"evidence_ref" => "operator-payment"})
    assert {:ok, [_]} = Log.append(step(f, courier, "delivered", 2, dropoff))
    head = Log.head()
    assert {:error, {:reject, 0, :duplicate_delivery_step}} =
             Log.append(step(f, courier, "delivered", 2, dropoff))
    assert Log.head() == head

    assert {:ok, %{requests: [row]}} = Procurement.snapshot(f.context)
    assert row.scope == {f.context.chapter_id, "coop", "request-1"}
    assert row.phase == :fulfilled and row.version == 7 and row.dispatch_phase == :delivered
    assert row.accepted_quote.revision == 1
    assert row.outcome_ref == "dispatch:" <> @dropoff
    assert [%{bank_verified: false}] = row.payment_evidence

    before = Procurement.state(Log.gate())
    :ok = restart_log()
    assert Procurement.state(Log.gate()) == before
    assert :ok = Log.verify_chains()
  end

  test "cancellation before claim leaves a cleanup job and route revocation blocks the signer", %{f: f} do
    :ok = F.quoted(f)
    {:ok, _} = F.submit(f, "accept", 3, F.acceptance())
    courier = new_member("procurement_dispatch", "dispatch-key")
    {:ok, [_]} = Log.append(route(f, courier, true, 0))
    :ok = Procurement.request_dispatch(f.context, "request-1", 4, @pick_digest, @drop_digest)
    assert {:ok, _} = F.submit(f, "cancel", 5, %{"evidence_ref" => "cancelled"})
    assert {:error, {:reject, 0, :delivery_order_not_ready}} = Log.append(step(f, courier, "accept", 0))
    assert [%{order_id: "request-1", phase: "cancelled"}] =
             ProcurementDispatch.work(Procurement.state(Log.gate()), f.context.chapter_id, "coop", @tenant, "")
    assert {:ok, [_]} = Log.append(route(f, courier, false, 1))
    assert {:error, {:reject, 0, :procurement_dispatch_forbidden}} =
             Log.append(step(f, courier, "accept", 0))
  end

  defp route(f, courier, active, expected) do
    F.event(f, "ProcurementDispatchRouteV1", %{
      "cooperative_id" => "coop", "tenant_id" => @tenant, "site" => "North dock",
      "key_id" => courier.signer.key_id, "pubkey" => {:bytes, courier.signer.pubkey},
      "active" => active, "expected_version" => expected
    })
  end

  defp step(f, courier, op, version, extra \\ %{}) do
    payload = Map.merge(%{
      "cooperative_id" => "coop", "order_id" => "request-1", "tenant_id" => @tenant,
      "load_id" => @load, "assignment_id" => @assignment, "command_id" => op,
      "op" => op, "expected_version" => version, "automated" => true
    }, extra)

    signed_event(courier, "ProcurementDispatchStepV1", payload,
      chapter_id: f.context.chapter_id, timestamp_ms: f.now)
  end

  test "signed workflow persists, audits and replays after expiry and restart", %{f: f} do
    :ok = F.quoted(f)
    {:ok, _} = F.submit(f, "accept", 3, F.acceptance())
    {:ok, _} = F.submit(f, "fulfill", 4, %{"evidence_ref" => "delivery-private"})
    {:ok, before} = Procurement.snapshot(f.context)
    assert [row] = before.requests
    assert row.phase == :fulfilled
    assert row.accepted_quote.total_minor == 12000
    assert row.payment_evidence == []
    head = Log.head()
    ProcurementTestClock.set(f.now + 10_000_000)
    :ok = restart_log()
    assert Log.head() == head
    assert :ok = Log.verify_chains()
    {:ok, replayed} = Log.replay(AdmissionGate)
    assert Procurement.state(replayed).requests[{"procurement-test", "coop", "request-1"}] == row
    assert {:error, _} = Procurement.snapshot(f.context)
  end

  test "exact retry is inert across restart but changed content is rejected", %{f: f} do
    c = F.command("request", 0, F.request(f))
    {:ok, first} = Procurement.submit(f.context, "request-1", c)
    head = Log.head()
    :ok = restart_log()
    assert {:ok, ^first} = Procurement.submit(f.context, "request-1", c)
    assert Log.head() == head
    changed = put_in(c, ["attrs", "quantity"], 99)
    assert {:error, :idempotency_conflict} = Procurement.submit(f.context, "request-1", changed)
    assert Log.head() == head
  end

  test "revocation blocks both snapshot and exact duplicate", %{f: f} do
    c = F.command("request", 0, F.request(f))
    {:ok, _} = Procurement.submit(f.context, "request-1", c)
    {:ok, _} = Log.append(F.grant(f, false, 1))
    head = Log.head()
    assert {:error, _} = Procurement.submit(f.context, "request-1", c)
    assert {:error, _} = Procurement.snapshot(f.context)
    assert Log.head() == head
  end

  test "raw Log append cannot bypass grant, signature or enrollment", %{f: f} do
    c = F.command("request", 0, F.request(f))
    {:ok, env} = Procurement.command(%{f.context | grant_version: 99}, "request-1", c)
    assert {:error, _} = Log.append(env)
    {:ok, env} = Procurement.command(f.context, "request-1", c)
    assert {:error, _} = Log.append(%{env | sigs: %{}})
    c = put_in(c, ["attrs", "buyer_business_id"], "not-enrolled")
    {:ok, env} = Procurement.command(f.context, "request-1", c)
    assert {:error, _} = Log.append(env)
  end

  test "private read is scoped and cannot be persisted", %{f: f} do
    {:ok, _} = F.submit(f, "request", 0, F.request(f))
    assert {:error, _} = Procurement.snapshot(%{f.context | cooperative_id: "other"})
    {:ok, read} = Procurement.snapshot_request(f.context)
    assert {:error, :snapshot_requests_are_not_log_events} = Log.append(read)
  end

  test "queued revocation is authoritative when later write reaches admission", %{f: f} do
    :ok = F.quoted(f)
    {:ok, write} = Procurement.command(f.context, "request-1", F.command("accept", 3, F.acceptance()))
    pid = GenServer.whereis(Log.server())
    :ok = :sys.suspend(pid)
    rev = make_ref()
    cmd = make_ref()
    send(pid, {:"$gen_call", {self(), rev}, {:append, [F.grant(f, false, 1)]}})
    send(pid, {:"$gen_call", {self(), cmd}, {:append, [write]}})
    :ok = :sys.resume(pid)
    assert_receive {^rev, {:ok, [_]}}, 5_000
    assert_receive {^cmd, {:error, _}}, 5_000
    assert Procurement.state(Log.gate()).requests[{"procurement-test", "coop", "request-1"}].phase == :qualified
  end

  test "competing accept/cancel at one version commit exactly once", %{f: f} do
    :ok = F.quoted(f)
    tasks = [
      Task.async(fn -> F.submit(f, "accept", 3, F.acceptance()) end),
      Task.async(fn -> F.submit(f, "cancel", 3, %{"evidence_ref" => "cancel-private"}) end)
    ]
    results = Enum.map(tasks, &Task.await(&1, 10_000))
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, _}, &1)) == 1
    row = Procurement.state(Log.gate()).requests[{"procurement-test", "coop", "request-1"}]
    assert row.version == 4
    assert row.phase in [:accepted, :cancelled]
  end

  test "old signed time cannot revive an expired quote or session", %{f: f} do
    :ok = F.quoted(f)
    {:ok, env} = Procurement.command(f.context, "request-1", F.command("accept", 3, F.acceptance()))
    ProcurementTestClock.set(f.now + 601_000)
    assert {:error, _} = Log.append(env)
    assert {:error, _} = F.submit(f, "accept", 3, F.acceptance())
    ProcurementTestClock.set(f.context.session_expires_at_ms)
    assert {:error, _} = Procurement.snapshot(f.context)
  end

  test "replacement grant invalidates old session; malformed attributes are closed", %{f: f} do
    {:ok, _} = Log.append(F.grant(f, true, 1))
    assert {:error, _} = Procurement.snapshot(f.context)
    assert {:ok, _} = Procurement.snapshot(%{f.context | grant_version: 2})
    c = F.command("request", 0, Map.put(F.request(f), "authorized", true))
    assert {:error, _} = Procurement.submit(%{f.context | grant_version: 2}, "request-1", c)
  end

  test "registry marks all procurement types private and signatures bind command", %{f: f} do
    assert Enum.all?(Procurement.event_types(), fn {_name, spec} -> spec.disclosure_class == :own_data end)
    {:ok, env} = Procurement.command(f.context, "request-1", F.command("request", 0, F.request(f)))
    forged = %{env | payload: put_in(env.payload, ["command", "attrs", "quantity"], 999)}
    assert {:error, _} = Envelope.verify(forged)
    assert {:error, _} = Log.append(forged)
  end
end
