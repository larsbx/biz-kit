defmodule CoopSubstrate.ProcurementTest do
  use CoopSubstrate.LogCase, async: false
  alias CoopSubstrate.{Log, Procurement, ProcurementDispatch, ProcurementFixture, ProcurementTestClock, ULID}
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

  defp step(f, courier, op, version, extra \\ %{}, signed_at \\ nil) do
    payload = Map.merge(%{
      "cooperative_id" => "coop", "order_id" => "request-1", "tenant_id" => @tenant,
      "load_id" => @load, "assignment_id" => @assignment, "command_id" => op,
      "op" => op, "expected_version" => version, "automated" => true
    }, extra)

    signed_event(courier, "ProcurementDispatchStepV1", payload,
      chapter_id: f.context.chapter_id, timestamp_ms: signed_at || f.now)
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

  test "one sourcing award survives replay and a delivery receipt cannot earn twice", %{f: f} do
    enroll_source = fn active, version ->
      F.event(f, "ProcurementBusinessEnrolledV1", %{
        "cooperative_id" => "coop", "business_id" => "source", "active" => active,
        "evidence_ref" => "source-enrollment", "expected_version" => version
      })
    end
    assert {:ok, [_]} = Log.append(enroll_source.(true, 0))

    submit = fn request_id, action, version, attrs, id ->
      Procurement.submit(f.context, request_id, F.command(action, version, attrs, id))
    end
    prepare = fn request_id ->
      actions = [
        {"request", F.request(f)},
        {"post_bounty", %{"reward_minor" => 500, "maximum_total_minor" => 13000, "terms_ref" => "bounty-terms"}},
        {"qualify", %{"evidence_ref" => "qualification"}},
        {"sourced_quote", Map.merge(F.quote_attrs(f), %{
          "sourcing_business_id" => "source", "sourcing_ref" => "private-attribution"
        })},
        {"sourced_quote", Map.merge(F.quote_attrs(f), %{
          "quote_id" => "quote-2", "sourcing_business_id" => "source", "sourcing_ref" => "alternate-attribution"
        })}
      ]
      for {{action, attrs}, version} <- Enum.with_index(actions) do
        assert {:ok, _} = submit.(request_id, action, version, attrs, nil)
      end
    end
    prepare.("wanted-1")

    assert {:ok, [_]} = Log.append(enroll_source.(false, 1))
    assert {:error, {:reject, 0, :business_not_enrolled}} =
             submit.("wanted-1", "accept", 5, F.acceptance(), nil)
    assert {:ok, [_]} = Log.append(enroll_source.(true, 2))

    results =
      ["quote-1", "quote-2"]
      |> Enum.map(fn quote_id ->
        Task.async(fn ->
          submit.("wanted-1", "accept", 5, %{F.acceptance() | "quote_id" => quote_id}, quote_id)
        end)
      end)
      |> Enum.map(&Task.await(&1, 10_000))
    assert [{:error, {:reject, 0, :stale_version}}, {:ok, accepted}] = Enum.sort(results)
    winner = accepted.payload["command"]["attrs"]["quote_id"]

    assert {:ok, _} = submit.("wanted-1", "fulfill", 6, %{"evidence_ref" => "delivery-1"}, nil)
    closeout = attest!(f, "wanted-1", 7, "closeout-1")
    assert {:ok, confirmed} =
             submit.("wanted-1", "confirm_bounty", 7, closeout, nil)
    before = Procurement.state(Log.gate())
    :ok = restart_log()
    assert Procurement.state(Log.gate()) == before
    assert {:ok, ^confirmed} =
             submit.("wanted-1", "confirm_bounty", 7, closeout, nil)
    assert {:ok, %{requests: [%{bounty: %{award: %{quote_id: ^winner, quote_revision: 1,
             delivery_ref: "delivery-1", closeout_ref: "closeout-1"}}}]}} = Procurement.snapshot(f.context)

    prepare.("wanted-2")
    assert {:ok, _} = submit.("wanted-2", "accept", 5, F.acceptance(), nil)
    assert {:ok, _} = submit.("wanted-2", "fulfill", 6, %{"evidence_ref" => "delivery-1"}, nil)
    reused_delivery = attest!(f, "wanted-2", 7, "closeout-2")
    head = Log.head()
    assert {:error, {:reject, 0, :bounty_evidence_already_used}} =
             submit.("wanted-2", "confirm_bounty", 7, reused_delivery, nil)
    assert Log.head() == head
    assert :ok = Log.verify_chains()
  end

  test "bounty result requires a signed attestation for the exact request and purpose", %{f: f} do
    enroll!(f, "source", true, 0)
    bounty_order!(f, "wanted-1")

    early = bounty_attestation(f, "wanted-1", 5, "buyer-closeout")
    assert {:error, {:reject, 0, :illegal_transition}} = Log.append(early)
    assert {:ok, _} = bounty_submit(f, "wanted-1", "fulfill", 5, %{"evidence_ref" => "delivery-1"})
    bounty_order!(f, "wanted-2", "delivery-2")

    other = put_in(f.context.cooperative_id, "other-coop")
    grant = F.event(other, "ProcurementOperatorGrantedV1", %{
      F.grant(f, true, 0).payload | "cooperative_id" => other.context.cooperative_id
    })
    assert {:ok, [_]} = Log.append(grant)
    for business <- ["buyer", "merchant", "source"], do: enroll!(other, business, true, 0)
    bounty_order!(other, "wanted-1", "delivery-1")

    head = Log.head()
    assert {:error, :invalid_command_attributes} =
             bounty_submit(f, "wanted-1", "confirm_bounty", 6, %{"evidence_ref" => "fabricated"})
    assert {:error, {:reject, 0, :bounty_attestation_scope_or_purpose_mismatch}} =
             bounty_submit(f, "wanted-1", "confirm_bounty", 6, %{"attestation_id" => ULID.generate()})

    valid = bounty_attestation(f, "wanted-1", 6, "buyer-closeout")
    rogue = new_member("governance", "rogue-bounty")
    unauthorized = signed_event(rogue, valid.type, valid.payload,
      chapter_id: valid.chapter_id, timestamp_ms: valid.timestamp_ms)
    assert {:error, {:reject, 0, :procurement_governance_required}} = Log.append(unauthorized)
    assert {:error, _} = Log.append(%{valid | payload: Map.put(valid.payload, "request_id", "wanted-2")})
    assert Log.head() == head

    assert {:ok, [attested]} = Log.append(valid)
    attrs = %{"attestation_id" => attested.event_id}
    head = Log.head()
    assert {:error, {:reject, 0, :bounty_attestation_scope_or_purpose_mismatch}} =
             bounty_submit(f, "wanted-2", "confirm_bounty", 6, attrs)
    assert {:error, {:reject, 0, :bounty_attestation_scope_or_purpose_mismatch}} =
             bounty_submit(other, "wanted-1", "confirm_bounty", 6, attrs)
    assert Log.head() == head
    assert {:ok, _} = bounty_submit(f, "wanted-1", "confirm_bounty", 6, attrs)

    head = Log.head()
    assert {:error, {:reject, 0, :bounty_attestation_scope_or_purpose_mismatch}} =
             bounty_submit(f, "wanted-1", "bounty_payment_evidence", 7, attrs)
    assert Log.head() == head
    payment = attest!(f, "wanted-1", 7, "ap-1", "external_payment")
    assert {:ok, _} = bounty_submit(f, "wanted-1", "bounty_payment_evidence", 7, payment)
    assert %{payment_evidence: [], bounty: %{award: %{closeout_ref: "buyer-closeout", payment_ref: "ap-1"}}} =
             bounty_row(f, "wanted-1")
    persisted = Procurement.state(Log.gate())
    :ok = restart_log()
    assert Procurement.state(Log.gate()) == persisted
  end

  test "bounty attestations expire at the cutoff and cannot follow a changed request version", %{f: f} do
    enroll!(f, "source", true, 0)
    bounty_order!(f, "wanted-1", "delivery-1")

    assert {:error, {:reject, 0, :stale_version}} =
             Log.append(bounty_attestation(f, "wanted-1", 5, "closeout-1"))
    stale = attest!(f, "wanted-1", 6, "closeout-1")
    expiring = attest!(f, "wanted-1", 6, "closeout-2", "closeout", f.now + 1_500)
    ProcurementTestClock.set(f.now + 1_500)
    head = Log.head()
    assert {:error, {:reject, 0, :bounty_attestation_expired}} =
             bounty_submit(f, "wanted-1", "confirm_bounty", 6, expiring)
    assert Log.head() == head

    assert {:ok, _} = bounty_submit(f, "wanted-1", "payment_evidence", 6, %{"evidence_ref" => "goods-ap"})
    head = Log.head()
    assert {:error, {:reject, 0, :stale_version}} =
             bounty_submit(f, "wanted-1", "confirm_bounty", 6, stale)
    assert {:error, {:reject, 0, :stale_bounty_attestation}} =
             bounty_submit(f, "wanted-1", "confirm_bounty", 7, stale)
    assert Log.head() == head
    fresh = attest!(f, "wanted-1", 7, "closeout-1")
    assert {:ok, _} = bounty_submit(f, "wanted-1", "confirm_bounty", 7, fresh)
  end

  test "duplicate, padded and wrong-stage references cannot be substituted for closeout", %{f: f} do
    enroll!(f, "source", true, 0)
    bounty_order!(f, "wanted-1")
    head = Log.head()
    for bad <- ["dispatch:fake", " padded", "padded ", " "] do
      assert {:error, {:reject, 0, :invalid_bounty_delivery_reference}} =
               bounty_submit(f, "wanted-1", "fulfill", 5, %{"evidence_ref" => bad})
    end
    assert Log.head() == head
    assert {:ok, _} = bounty_submit(f, "wanted-1", "fulfill", 5, %{"evidence_ref" => "delivery-1"})
    head = Log.head()
    for bad <- ["delivery-1", "bounty-terms", "buyer-consent-private", "buyer-acceptance-private",
                "merchant-quote-private", "private-attribution"] do
      assert {:error, {:reject, 0, :bounty_evidence_already_used}} =
               Log.append(bounty_attestation(f, "wanted-1", 6, bad))
    end
    for bad <- ["dispatch:fake", " closeout", "closeout ", " "] do
      assert {:error, {:reject, 0, :invalid_bounty_attestation_reference}} =
               Log.append(bounty_attestation(f, "wanted-1", 6, bad))
    end
    assert Log.head() == head
    closeout = attest!(f, "wanted-1", 6, "closeout-1")
    assert {:ok, _} = bounty_submit(f, "wanted-1", "confirm_bounty", 6, closeout)
    assert {:error, {:reject, 0, :bounty_evidence_already_used}} =
             Log.append(bounty_attestation(f, "wanted-1", 7, "closeout-1", "external_payment"))
  end

  test "each business must still be enrolled and reenrollment invalidates outstanding attestations", %{f: f} do
    enroll!(f, "source", true, 0)
    bounty_order!(f, "wanted-1", "delivery-1")
    candidates = ["buyer", "merchant", "source"]

    for id <- candidates do
      closeout = attest!(f, "wanted-1", 6, "closeout-1")
      enroll!(f, id, false, 1)
      head = Log.head()
      assert {:error, {:reject, 0, :business_not_enrolled}} =
               bounty_submit(f, "wanted-1", "confirm_bounty", 6, closeout)
      assert {:error, {:reject, 0, :business_not_enrolled}} =
               Log.append(bounty_attestation(f, "wanted-1", 6, "closeout-2"))
      assert Log.head() == head
      enroll!(f, id, true, 2)
      assert {:error, {:reject, 0, :stale_bounty_attestation}} =
               bounty_submit(f, "wanted-1", "confirm_bounty", 6, closeout)
    end

    closeout = attest!(f, "wanted-1", 6, "closeout-1")
    assert {:ok, _} = bounty_submit(f, "wanted-1", "confirm_bounty", 6, closeout)
    payment = attest!(f, "wanted-1", 7, "ap-1", "external_payment")
    enroll!(f, "source", false, 3)
    assert {:error, {:reject, 0, :business_not_enrolled}} =
             bounty_submit(f, "wanted-1", "bounty_payment_evidence", 7, payment)
  end

  test "one same-request confirmation commits and its exact retry adds no event", %{f: f} do
    enroll!(f, "source", true, 0)
    bounty_order!(f, "wanted-1", "delivery-1")
    commands =
      for reference <- ["closeout-1", "closeout-2"] do
        attrs = attest!(f, "wanted-1", 6, reference)
        F.command("confirm_bounty", 6, attrs, reference)
      end

    before = Log.head().global_seq
    tasks = Enum.map(commands, fn command ->
      Task.async(fn -> Procurement.submit(f.context, "wanted-1", command) end)
    end)
    results = Enum.map(tasks, &Task.await(&1, 10_000))
    assert [{:error, {:reject, 0, :stale_version}}, {:ok, committed}] = Enum.sort(results)
    assert Log.head().global_seq == before + 1
    assert bounty_row(f, "wanted-1").version == 7
    assert {:ok, ^committed} =
             Procurement.submit(f.context, "wanted-1", committed.payload["command"])
    assert Log.head().global_seq == before + 1
    assert :ok = Log.verify_chains()
  end

  test "concurrent requests cannot consume the same closeout reference", %{f: f} do
    enroll!(f, "source", true, 0)
    candidates = for id <- ["wanted-1", "wanted-2"] do
      bounty_order!(f, id, "delivery-" <> id)
      {id, attest!(f, id, 6, "shared-closeout")}
    end

    before = Log.head().global_seq
    tasks = Enum.map(candidates, fn {id, attrs} ->
      Task.async(fn -> bounty_submit(f, id, "confirm_bounty", 6, attrs) end)
    end)
    results = Enum.map(tasks, &Task.await(&1, 10_000))
    assert [{:error, {:reject, 0, :bounty_evidence_already_used}}, {:ok, _}] = Enum.sort(results)
    assert Log.head().global_seq == before + 1
    assert Enum.sort(Enum.map(candidates, fn {id, _} -> bounty_row(f, id).version end)) == [6, 7]
  end

  test "a queued dispute fences both closeout and payment after the request changes", %{f: f} do
    enroll!(f, "source", true, 0)
    for {id, action, purpose, version} <- [
          {"wanted-1", "confirm_bounty", "closeout", 6},
          {"wanted-2", "bounty_payment_evidence", "external_payment", 7}
        ] do
      bounty_order!(f, id, "delivery-" <> id)
      if action == "bounty_payment_evidence" do
        closeout = attest!(f, id, 6, "earlier-closeout")
        assert {:ok, _} = bounty_submit(f, id, "confirm_bounty", 6, closeout)
      end
      attrs = attest!(f, id, version, "final-" <> id, purpose)
      {:ok, dispute} = Procurement.command(f.context, id,
        F.command("dispute", version, %{"evidence_ref" => "buyer-dispute"}))
      {:ok, attempt} = Procurement.command(f.context, id, F.command(action, version, attrs))
      before = Log.head().global_seq
      assert [{:ok, [_]}, {:error, {:reject, 0, :stale_version}}] = append_in_order(dispute, attempt)
      assert Log.head().global_seq == before + 1
      assert {:error, {:reject, 0, :illegal_transition}} =
               bounty_submit(f, id, action, version + 1, attrs)
      assert %{phase: :disputed, bounty: %{award: %{payment_ref: nil}}} = bounty_row(f, id)
    end
    assert bounty_row(f, "wanted-1").bounty.award.closeout_ref == nil
    assert bounty_row(f, "wanted-2").bounty.award.closeout_ref == "earlier-closeout"
  end

  test "a queued operator revocation fences a signed closeout using a valid attestation", %{f: f} do
    enroll!(f, "source", true, 0)
    bounty_order!(f, "wanted-1", "delivery-1")
    attrs = attest!(f, "wanted-1", 6, "closeout-1")
    {:ok, attempt} = Procurement.command(f.context, "wanted-1", F.command("confirm_bounty", 6, attrs))
    before = Log.head().global_seq
    assert [{:ok, [_]}, {:error, :procurement_forbidden}] =
             append_in_order(F.grant(f, false, 1), attempt)
    assert Log.head().global_seq == before + 1
    assert bounty_row(f, "wanted-1").bounty.award.closeout_ref == nil
  end

  test "manual delivery at or past a subsecond exclusive deadline cannot become timely", %{f: f} do
    enroll!(f, "source", true, 0)
    deadline = f.now + 1_500
    request = %{F.request(f) | "needed_by_ms" => deadline}
    bounty_order!(f, "wanted-1", nil, request)
    bounty_order!(f, "wanted-2", nil, request)
    ProcurementTestClock.set(deadline - 1)
    assert {:ok, _} = bounty_submit(f, "wanted-1", "fulfill", 5, %{"evidence_ref" => "timely"})
    ProcurementTestClock.set(deadline)
    head = Log.head()
    assert {:error, {:reject, 0, :bounty_delivery_time_ambiguous}} =
             bounty_submit(f, "wanted-2", "fulfill", 5, %{"evidence_ref" => "at-cutoff"})
    assert Log.head() == head
    ProcurementTestClock.set(f.now + 2_000)
    assert {:ok, _} = bounty_submit(f, "wanted-2", "fulfill", 5, %{"evidence_ref" => "late"})
    assert {:error, {:reject, 0, :bounty_result_not_admissible}} =
             Log.append(bounty_attestation(f, "wanted-2", 6, "late-closeout"))
    timely = attest!(f, "wanted-1", 6, "timely-closeout")
    assert {:ok, _} = bounty_submit(f, "wanted-1", "confirm_bounty", 6, timely)
    before = Procurement.state(Log.gate())
    :ok = restart_log()
    assert Procurement.state(Log.gate()) == before
  end

  test "a signed Dispatch handoff exactly at the exclusive cutoff records late delivery", %{f: f} do
    enroll!(f, "source", true, 0)
    deadline = f.now + 1_500
    bounty_order!(f, "request-1", nil, %{F.request(f) | "needed_by_ms" => deadline})
    courier = new_member("procurement_dispatch", "dispatch-key")
    assert {:ok, [_]} = Log.append(route(f, courier, true, 0))
    assert :ok = Procurement.request_dispatch(f.context, "request-1", 5, @pick_digest, @drop_digest)
    assert {:ok, [_]} = Log.append(step(f, courier, "accept", 0))
    pickup = %{"proof_id" => @pickup, "proof_digest" => @pick_digest}
    assert {:ok, [_]} = Log.append(step(f, courier, "picked_up", 1, pickup))

    ProcurementTestClock.set(deadline)
    dropoff = %{"proof_id" => @dropoff, "proof_digest" => @drop_digest}
    assert {:ok, [_]} = Log.append(step(f, courier, "delivered", 2, dropoff, deadline))
    assert %{phase: :fulfilled, bounty: %{award: %{delivered_on_time: false}}} =
             bounty_row(f, "request-1")
    head = Log.head()
    assert {:error, {:reject, 0, :bounty_result_not_admissible}} =
             Log.append(bounty_attestation(f, "request-1", 7, "late-dispatch-closeout"))
    assert Log.head() == head
  end

  defp bounty_order!(f, id, delivery \\ nil, wanted \\ nil) do
    sourced = Map.merge(F.quote_attrs(f), %{"sourcing_business_id" => "source",
      "sourcing_ref" => "private-attribution"})
    commands = [
      {"request", wanted || F.request(f)},
      {"post_bounty", %{"reward_minor" => 500, "maximum_total_minor" => 13000, "terms_ref" => "bounty-terms"}},
      {"qualify", %{"evidence_ref" => "qualification"}},
      {"sourced_quote", sourced},
      {"accept", F.acceptance()}
    ]
    commands = if delivery, do: commands ++ [{"fulfill", %{"evidence_ref" => delivery}}], else: commands
    for {{action, attrs}, version} <- Enum.with_index(commands) do
      assert {:ok, _} = bounty_submit(f, id, action, version, attrs)
    end
  end

  defp enroll!(f, id, active, version) do
    assert {:ok, [_]} = Log.append(F.event(f, "ProcurementBusinessEnrolledV1", %{
      "cooperative_id" => f.context.cooperative_id, "business_id" => id, "active" => active,
      "evidence_ref" => "enrollment-" <> id, "expected_version" => version
    }))
  end

  defp bounty_attestation(f, id, version, reference, purpose \\ "closeout", expires \\ nil),
    do: F.bounty_attestation(f, id, purpose, version, reference, expires || f.now + 60_000)

  defp attest!(f, id, version, reference, purpose \\ "closeout", expires \\ nil) do
    assert {:ok, [event]} = Log.append(bounty_attestation(f, id, version, reference, purpose, expires))
    %{"attestation_id" => event.event_id}
  end

  defp bounty_submit(f, id, action, version, attrs),
    do: Procurement.submit(f.context, id, F.command(action, version, attrs))

  defp bounty_row(f, id),
    do: Procurement.state(Log.gate()).requests[{f.context.chapter_id, f.context.cooperative_id, id}]

  defp append_in_order(first, second) do
    pid = GenServer.whereis(Log.server())
    :ok = :sys.suspend(pid)
    first_ref = make_ref()
    second_ref = make_ref()
    send(pid, {:"$gen_call", {self(), first_ref}, {:append, [first]}})
    send(pid, {:"$gen_call", {self(), second_ref}, {:append, [second]}})
    :ok = :sys.resume(pid)
    assert_receive {^first_ref, first_result}, 5_000
    assert_receive {^second_ref, second_result}, 5_000
    [first_result, second_result]
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
