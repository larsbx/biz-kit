defmodule CoopSubstrate.ProcurementTest do
  use CoopSubstrate.LogCase, async: false
  alias CoopSubstrate.{Log, Procurement, ProcurementFixture, ProcurementTestClock}
  alias CoopSubstrate.Projections.AdmissionGate
  alias CoopSubstrate.Protocol.Envelope
  alias ProcurementFixture, as: F
  setup do
    {:ok, f: F.setup()}
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
