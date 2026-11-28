defmodule CoopSubstrate.RestaurantKeyAuditTest do
  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.{
    Canonical,
    Log,
    ProcurementTestClock,
    ReleaseTasks,
    RestaurantKeyAudit,
    ULID
  }

  alias CoopSubstrate.Projections.Membership
  alias CoopSubstrate.Protocol.Envelope

  @chapter "chapter-genesis"
  @other_chapter "chapter-two"
  @tenant_a "11111111-1111-1111-1111-111111111111"
  @tenant_b "22222222-2222-2222-2222-222222222222"
  @now 1_800_000_000_000

  test "reports all four historical rules in ledger order with exact event provenance" do
    gov = new_member("governance")
    shared = new_member()
    first_role = new_member()
    later_role = new_member()
    cross_tenant = new_member()
    dispatch_regrant = new_member()
    active_duplicate = new_member()

    events =
      load_synthetic_history!(
        genesis: role(gov, "governance", gov.signer.key_id, gov),
        old_device: device(gov, "pizza", "pos-old", shared),
        revoke_device: revoke_grant(gov, "pizza", "pos-old"),
        shared_dispatch: dispatch(gov, "pizza", @tenant_a, "courier", shared),
        revoke_shared: revoke_grant(gov, "pizza", "courier"),
        shared_device: device(gov, "deli", "board", shared),
        old_role: role(gov, "checkpoint", "checkpoint", first_role),
        first_role_dispatch: dispatch(gov, "deli", @tenant_a, "first-role", first_role),
        revoke_role: revoke_role(gov, "checkpoint", "checkpoint"),
        old_dispatch: dispatch(gov, "deli", @tenant_a, "later-role", later_role),
        revoke_dispatch: revoke_grant(gov, "deli", "later-role"),
        new_role: role(gov, "steward", "steward", later_role),
        first_tenant: dispatch(gov, "pizza", @tenant_a, "first-tenant", cross_tenant),
        revoke_tenant: revoke_grant(gov, "pizza", "first-tenant"),
        same_tenant: dispatch(gov, "diner", @tenant_a, "same-tenant", cross_tenant),
        second_tenant: dispatch(gov, "deli", @tenant_b, "second-tenant", cross_tenant),
        old_dispatch_grant: dispatch(gov, "deli", @tenant_a, "old-courier", dispatch_regrant),
        revoke_dispatch_grant: revoke_grant(gov, "deli", "old-courier"),
        new_dispatch_grant: dispatch(gov, "deli", @tenant_a, "new-courier", dispatch_regrant),
        first_active: device(gov, "deli", "active-first", active_duplicate),
        second_active: device(gov, "deli", "active-second", active_duplicate)
      )

    head = Log.head()
    {:ok, before} = Log.replay(Membership)
    {:ok, records} = Log.read_all()

    assert {:ok, %{as_of: as_of, violation_count: 8, historical_violations: findings} = report} =
             RestaurantKeyAudit.scan()

    assert as_of == %{global_seq: head.global_seq, global_hash: hex(head.global_hash)}
    assert report.schema == "restaurant-key-collision-audit.v2"
    assert report.open_count == 6

    expected = [
      {:device_dispatch_key_reuse, :shared_dispatch, [:old_device]},
      {:merchant_key_reuse, :shared_dispatch, [:old_device]},
      {:device_dispatch_key_reuse, :shared_device, [:shared_dispatch]},
      {:dispatch_role_key_reuse, :first_role_dispatch, [:old_role]},
      {:dispatch_role_key_reuse, :new_role, [:old_dispatch]},
      {:dispatch_cross_tenant_key_reuse, :second_tenant, [:first_tenant, :same_tenant]},
      {:merchant_key_reuse, :new_dispatch_grant, [:old_dispatch_grant]},
      {:merchant_key_reuse, :second_active, [:first_active]}
    ]

    # One row per later event and rule, with every earlier witness in order.
    assert length(findings) == length(expected)

    revocations = %{
      old_device: events.revoke_device,
      shared_dispatch: events.revoke_shared,
      old_role: events.revoke_role,
      old_dispatch: events.revoke_dispatch,
      first_tenant: events.revoke_tenant,
      old_dispatch_grant: events.revoke_dispatch_grant
    }

    # A binding is live at the head until its grant or role key is revoked.
    live = Map.keys(events) -- Map.keys(revocations)

    for {finding, {rule, later, earlier}} <- Enum.zip(findings, expected) do
      assert finding.rule == rule

      refusal = if rule == :merchant_key_reuse, do: :restaurant_key_already_granted
      assert finding.refusal == (refusal || :key_not_separate)

      {:bytes, pubkey} = events[later].payload["pubkey"]
      assert finding.pubkey_sha256 == hex(:crypto.hash(:sha256, pubkey))
      assert_evidence(finding.event, events[later], revocations[later])
      assert finding.event.active_at_head == later in live
      assert length(finding.earlier_events) == length(earlier)

      for {ref, name} <- Enum.zip(finding.earlier_events, earlier) do
        assert_evidence(ref, events[name], revocations[name])
        assert ref.active_at_head == name in live
      end

      assert_remediation(finding, for(name <- [later | earlier], name in live, do: events[name]))
    end

    assert Log.head() == head
    assert Log.read_all() == {:ok, records}
    assert Log.replay(Membership) == {:ok, before}
    assert Log.gate().restaurant == before.restaurant
    assert RestaurantKeyAudit.scan(head) == {:ok, report}
  end

  test "allows the same key across chapter boundaries and legitimate merchant reuse" do
    gov = new_member("governance")
    other_gov = new_member("governance")
    shared_device = new_member()
    shared_dispatch = new_member()
    role_elsewhere = new_member()
    rotated_key = new_member()
    replacement = new_member()

    assert {:ok, _} =
             Log.append([
               role(gov, "governance", gov.signer.key_id, gov),
               role(other_gov, "governance", other_gov.signer.key_id, other_gov, @other_chapter),
               device(gov, "shared-merchant", "device", shared_device),
               revoke_grant(gov, "shared-merchant", "device"),
               device(gov, "other-merchant", "device", shared_device),
               dispatch(
                 other_gov,
                 "shared-merchant",
                 @tenant_b,
                 "device",
                 shared_device,
                 @other_chapter
               ),
               role(other_gov, "checkpoint", "outside", role_elsewhere, @other_chapter),
               device(gov, "third-merchant", "outside", role_elsewhere),
               role(gov, "checkpoint", "rotated", shared_dispatch),
               revoke_role(gov, "checkpoint", "rotated"),
               role(gov, "checkpoint", "rotated", rotated_key),
               dispatch(gov, "shared-merchant", @tenant_a, "courier", shared_dispatch),
               revoke_grant(gov, "shared-merchant", "courier"),
               dispatch(gov, "other-merchant", @tenant_a, "courier", shared_dispatch),
               dispatch(
                 other_gov,
                 "shared-merchant",
                 @tenant_b,
                 "courier",
                 shared_dispatch,
                 @other_chapter
               ),
               role(other_gov, "steward", "operator", replacement, @other_chapter),
               device(gov, "third-merchant", "device", replacement)
             ])

    assert {:ok, %{violation_count: 0, historical_violations: []}} = RestaurantKeyAudit.scan()
  end

  test "uses the active role declaration when a revoked role key ID is declared again" do
    gov = new_member("governance")
    key = new_member()

    events =
      load_synthetic_history!(
        genesis: role(gov, "governance", gov.signer.key_id, gov),
        retired: role(gov, "checkpoint", "reviewer", key),
        first_revoke: revoke_role(gov, "checkpoint", "reviewer"),
        redeclared: role(gov, "checkpoint", "reviewer", key),
        dispatch: dispatch(gov, "pizza", @tenant_a, "courier", key),
        second_revoke: revoke_role(gov, "checkpoint", "reviewer")
      )

    assert {:ok, %{historical_violations: [finding]}} = RestaurantKeyAudit.scan()
    assert finding.rule == :dispatch_role_key_reuse
    assert_evidence(finding.event, events.dispatch, nil)
    assert [earlier] = finding.earlier_events
    assert_evidence(earlier, events.redeclared, events.second_revoke)
  end

  test "pins a prefix, refuses an unknown head and excludes an attempted admission" do
    gov = new_member("governance")
    key = new_member()

    assert {:ok, %{as_of: %{global_seq: 0, global_hash: nil}, violation_count: 0}} =
             RestaurantKeyAudit.scan()

    assert {:ok, _} = Log.append(role(gov, "governance", gov.signer.key_id, gov))
    captured = Log.head()
    assert {:ok, first_report} = RestaurantKeyAudit.scan(captured)
    assert {:ok, _} = Log.append(device(gov, "pizza", "device", key))
    assert RestaurantKeyAudit.scan(captured) == {:ok, first_report}

    assert RestaurantKeyAudit.scan(%{captured | global_hash: <<0::256>>}) ==
             {:error, :ledger_head_mismatch}

    latest = Log.head()

    assert RestaurantKeyAudit.scan(%{latest | global_seq: latest.global_seq + 1}) ==
             {:error, :ledger_head_mismatch}

    assert {:ok, current_report} = RestaurantKeyAudit.scan()

    assert {:error, {:reject, 0, :restaurant_key_already_granted}} =
             Log.append(device(gov, "pizza", "device", key))

    assert Log.head() == latest
    assert RestaurantKeyAudit.scan() == {:ok, current_report}
  end

  test "returns no report for a record with an invalid signature" do
    gov = new_member("governance")
    assert {:ok, [event]} = Log.append(role(gov, "governance", gov.signer.key_id, gov))
    key_id = gov.signer.key_id
    damaged = %{event | sigs: %{key_id => <<0::512>>}}
    original_bytes = Canonical.encode!(Envelope.full_record_term(event))
    damaged_bytes = Canonical.encode!(Envelope.full_record_term(damaged))
    update = "UPDATE events SET data = $1 WHERE event_type = $2"

    with_update_bypass(fn conn ->
      assert %{num_rows: 1} =
               Postgrex.query!(conn, update, [damaged_bytes, event.type])

      try do
        assert {:error,
                {:unverified_ledger_prefix,
                 {:break, 1, [{:signature, {:invalid_signature, ^key_id}}]}}} =
                 RestaurantKeyAudit.scan()
      after
        Postgrex.query!(conn, update, [original_bytes, event.type])
      end
    end)

    assert :ok = Log.verify_chains()
  end

  test "a device on the governance key stays open until both bindings are retired" do
    gov = new_member("governance")
    successor = new_member("governance")

    events =
      load_synthetic_history!(
        genesis: role(gov, "governance", gov.signer.key_id, gov),
        device: device(gov, "pizza", "pos", gov)
      )

    assert_raise RuntimeError, ~r/key audit: 1 open finding\(s\) of 1/, fn ->
      ReleaseTasks.audit_keys(puts: &send(self(), {:printed, &1}))
    end

    assert_received {:printed, json}
    assert %{"open_count" => 1, "violation_count" => 1} = Jason.decode!(json)

    assert {:ok, %{open_count: 1, historical_violations: [finding]}} = RestaurantKeyAudit.scan()
    assert finding.rule == :device_role_key_reuse
    assert finding.refusal == :key_not_separate
    assert_evidence(finding.event, events.device, nil)
    assert [earlier] = finding.earlier_events
    assert_evidence(earlier, events.genesis, nil)
    assert_remediation(finding, [events.device, events.genesis])

    assert {:ok, [revoked]} = Log.append(revoke_grant(gov, "pizza", "pos"))
    assert {:ok, %{open_count: 1, historical_violations: [finding]}} = RestaurantKeyAudit.scan()
    assert_evidence(finding.event, events.device, revoked)
    refute finding.event.active_at_head
    assert_remediation(finding, [events.genesis])

    assert {:ok, _} = Log.append(role(gov, "governance", successor.signer.key_id, successor))

    assert {:ok, [retired]} =
             Log.append(revoke_role(successor, "governance", gov.signer.key_id))

    assert {:ok, %{open_count: 0, violation_count: 1, historical_violations: [finding]} = report} =
             ReleaseTasks.audit_keys(puts: fn _ -> :ok end)

    assert [earlier] = finding.earlier_events
    assert_evidence(earlier, events.genesis, retired)
    refute finding.open
    assert finding.remediation == %{}
    assert RestaurantKeyAudit.scan() == {:ok, report}
  end

  test "a role key on a revoked device key is a finding; a device on a revoked role key is not" do
    gov = new_member("governance")
    device_key = new_member()
    role_key = new_member()

    events =
      load_synthetic_history!(
        genesis: role(gov, "governance", gov.signer.key_id, gov),
        device: device(gov, "pizza", "pos", device_key),
        revoke_device: revoke_grant(gov, "pizza", "pos"),
        steward: role(gov, "steward", "steward", device_key),
        checkpoint: role(gov, "checkpoint", "checkpoint", role_key),
        revoke_checkpoint: revoke_role(gov, "checkpoint", "checkpoint"),
        board: device(gov, "pizza", "board", role_key)
      )

    assert {:ok, %{open_count: 1, historical_violations: [finding]}} = RestaurantKeyAudit.scan()
    assert finding.rule == :device_role_key_reuse
    assert_evidence(finding.event, events.steward, nil)
    assert [earlier] = finding.earlier_events
    assert_evidence(earlier, events.device, events.revoke_device)
    refute earlier.active_at_head
    assert_remediation(finding, [events.steward])
  end

  test "a role key ID declared again on a fresh key no longer holds the old key" do
    gov = new_member("governance")
    key = new_member()

    events =
      load_synthetic_history!(
        genesis: role(gov, "governance", gov.signer.key_id, gov),
        steward: role(gov, "steward", "steward", key),
        device: device(gov, "pizza", "pos", key)
      )

    assert {:ok, [retired]} = Log.append(revoke_role(gov, "steward", "steward"))
    assert {:ok, _} = Log.append(role(gov, "steward", "steward", new_member()))
    assert {:ok, %{open_count: 1, historical_violations: [finding]}} = RestaurantKeyAudit.scan()
    assert finding.rule == :device_role_key_reuse
    assert_evidence(finding.event, events.device, nil)
    assert [earlier] = finding.earlier_events
    assert_evidence(earlier, events.steward, retired)
    refute earlier.active_at_head
    assert_remediation(finding, [events.device])

    assert {:ok, _} = Log.append(revoke_grant(gov, "pizza", "pos"))
    assert {:ok, %{open_count: 0, violation_count: 1}} = RestaurantKeyAudit.scan()
  end

  test "a finding's evidence and liveness stay in its chapter" do
    gov = new_member("governance")
    other_gov = new_member("governance")
    key = new_member()

    events =
      load_synthetic_history!(
        genesis: role(gov, "governance", gov.signer.key_id, gov),
        other_genesis:
          role(other_gov, "governance", other_gov.signer.key_id, other_gov, @other_chapter),
        steward: role(gov, "steward", "steward", key),
        other_steward: role(other_gov, "steward", "steward", key, @other_chapter),
        device: device(gov, "pizza", "pos", key)
      )

    assert {:ok, %{open_count: 1, historical_violations: [finding]}} = RestaurantKeyAudit.scan()
    assert finding.rule == :device_role_key_reuse
    assert_evidence(finding.event, events.device, nil)
    assert [earlier] = finding.earlier_events
    assert_evidence(earlier, events.steward, nil)

    assert {:ok, _} = Log.append(revoke_grant(gov, "pizza", "pos"))
    assert {:ok, _} = Log.append(revoke_role(gov, "steward", "steward"))
    assert {:ok, %{open_count: 0, violation_count: 1}} = RestaurantKeyAudit.scan()
  end

  test "a dispatcher on a restaurant Dispatch key is another holder's, and never closes" do
    gov = new_member("governance")
    key = new_member()

    events =
      load_synthetic_history!(
        genesis: role(gov, "governance", gov.signer.key_id, gov),
        dispatch: dispatch(gov, "pizza", @tenant_a, "courier", key),
        dispatcher: dispatcher(gov, @tenant_a, "x1", key)
      )

    assert {:ok, [revoked]} = Log.append(revoke_grant(gov, "pizza", "courier"))
    assert {:ok, %{open_count: 1, historical_violations: [finding]}} = RestaurantKeyAudit.scan()
    assert finding.rule == :holder_key_reuse
    assert finding.refusal == :key_not_separate
    assert_evidence(finding.event, events.dispatcher, nil)
    assert finding.event.dispatcher_id == "dispatcher-x1"
    assert [earlier] = finding.earlier_events
    assert_evidence(earlier, events.dispatch, revoked)
    assert_remediation(finding, [events.dispatcher])
  end

  test "a route on an operator's key stays open until both slots are deactivated" do
    ProcurementTestClock.set(@now)
    gov = new_member("governance")
    key = new_member()

    events =
      load_synthetic_history!(
        genesis: role(gov, "governance", gov.signer.key_id, gov),
        operator: operator(gov, "c1", "o1", key, 0),
        route: route(gov, "c1", key, 0)
      )

    assert {:ok, %{open_count: 1, historical_violations: [finding]}} = RestaurantKeyAudit.scan()
    assert finding.rule == :holder_key_reuse
    assert_evidence(finding.event, events.route, nil)
    assert finding.event.cooperative_id == "c1"
    assert [earlier] = finding.earlier_events
    assert_evidence(earlier, events.operator, nil)
    assert earlier.operator_id == "o1"
    assert_remediation(finding, [events.route, events.operator])

    # Deactivating either slot re-sends its key, and the fence never refuses it.
    assert {:ok, _} = Log.append(route(gov, "c1", key, 1, false))
    assert {:ok, %{open_count: 1, historical_violations: [finding]}} = RestaurantKeyAudit.scan()
    refute finding.event.active_at_head
    assert [%{active_at_head: true}] = finding.earlier_events
    assert finding.open
    assert_remediation(finding, [events.operator])

    assert {:ok, _} = Log.append(operator(gov, "c1", "o1", key, 1, false))

    assert {:ok, %{open_count: 0, violation_count: 1, historical_violations: [finding]}} =
             RestaurantKeyAudit.scan()

    refute finding.open
    assert finding.remediation == %{}
  end

  test "a route on an operator's key closes once both slots rotate to fresh keys" do
    ProcurementTestClock.set(@now)
    gov = new_member("governance")
    key = new_member()

    load_synthetic_history!(
      genesis: role(gov, "governance", gov.signer.key_id, gov),
      operator: operator(gov, "c1", "o1", key, 0),
      route: route(gov, "c1", key, 0)
    )

    assert {:ok, _} = Log.append(route(gov, "c1", new_member(), 1))
    assert {:ok, _} = Log.append(operator(gov, "c1", "o1", new_member(), 1))

    assert {:ok, %{open_count: 0, violation_count: 1, historical_violations: [finding]}} =
             RestaurantKeyAudit.scan()

    assert finding.remediation == %{}
  end

  test "a slot's liveness stays in its chapter" do
    ProcurementTestClock.set(@now)
    gov = new_member("governance")
    other_gov = new_member("governance")
    key = new_member()

    load_synthetic_history!(
      genesis: role(gov, "governance", gov.signer.key_id, gov),
      other_genesis:
        role(other_gov, "governance", other_gov.signer.key_id, other_gov, @other_chapter),
      operator: operator(gov, "c1", "o1", key, 0),
      route: route(gov, "c1", key, 0),
      other_operator: operator(other_gov, "c1", "o1", key, 0, true, @other_chapter),
      other_route: route(other_gov, "c1", key, 0, true, @other_chapter)
    )

    assert {:ok, %{open_count: 2, violation_count: 2}} = RestaurantKeyAudit.scan()
    assert {:ok, _} = Log.append(route(gov, "c1", key, 1, false))
    assert {:ok, _} = Log.append(operator(gov, "c1", "o1", key, 1, false))

    assert {:ok, %{open_count: 1, violation_count: 2, historical_violations: [closed, open]}} =
             RestaurantKeyAudit.scan()

    refute closed.open
    assert closed.event.chapter_id == @chapter
    assert open.open
    assert open.event.chapter_id == @other_chapter
  end

  test "a deactivation binds nothing, so a later collision names the active version" do
    ProcurementTestClock.set(@now)
    gov = new_member("governance")
    key = new_member()

    events =
      load_synthetic_history!(
        genesis: role(gov, "governance", gov.signer.key_id, gov),
        route: route(gov, "c1", key, 0),
        deactivated: route(gov, "c1", key, 1, false),
        device: device(gov, "pizza", "pos", key)
      )

    assert {:ok, %{open_count: 1, historical_violations: [finding]}} = RestaurantKeyAudit.scan()
    assert finding.rule == :holder_key_reuse
    assert_evidence(finding.event, events.device, nil)
    assert [earlier] = finding.earlier_events
    assert_evidence(earlier, events.route, nil)
    refute earlier.active_at_head
    assert_remediation(finding, [events.device])
  end

  test "a key a route rotated away keeps its holder, and is no longer live there" do
    ProcurementTestClock.set(@now)
    gov = new_member("governance")
    first = new_member()
    second = new_member()

    events =
      load_synthetic_history!(
        genesis: role(gov, "governance", gov.signer.key_id, gov),
        route: route(gov, "c1", first, 0),
        rotated: route(gov, "c1", second, 1),
        device: device(gov, "pizza", "pos", first)
      )

    assert {:ok, %{open_count: 1, historical_violations: [finding]}} = RestaurantKeyAudit.scan()
    assert finding.rule == :holder_key_reuse
    assert_evidence(finding.event, events.device, nil)
    assert [earlier] = finding.earlier_events
    assert_evidence(earlier, events.route, nil)
    refute earlier.active_at_head
    assert_remediation(finding, [events.device])
  end

  test "Log.stored_head/0 reads the head from the ledger, as the appender holds it" do
    gov = new_member("governance")
    assert Log.stored_head() == {:ok, %{global_seq: 0, global_hash: nil}}
    assert {:ok, _} = Log.append(role(gov, "governance", gov.signer.key_id, gov))
    assert {:ok, _} = Log.append(device(gov, "pizza", "pos", new_member()))
    assert Log.stored_head() == {:ok, Log.head()}
  end

  test "audit_keys prints the report at the stored head, or at a pinned one" do
    gov = new_member("governance")
    puts = &send(self(), {:printed, &1})
    assert {:ok, _} = Log.append(role(gov, "governance", gov.signer.key_id, gov))
    {:ok, head} = Log.stored_head()

    assert {:ok, %{open_count: 0, violation_count: 0} = report} =
             ReleaseTasks.audit_keys(puts: puts)

    assert {:ok, report} == RestaurantKeyAudit.scan(head)
    assert_received {:printed, json}
    assert Jason.decode!(json) == Jason.decode!(Jason.encode!(report))

    assert Jason.decode!(json)["as_of"] == %{
             "global_seq" => head.global_seq,
             "global_hash" => hex(head.global_hash)
           }

    as_of = "#{head.global_seq}:#{hex(head.global_hash)}"
    assert {:ok, _} = Log.append(device(gov, "pizza", "pos", new_member()))
    assert ReleaseTasks.audit_keys(as_of: as_of, puts: puts) == {:ok, report}
    assert ReleaseTasks.audit_keys(as_of: String.upcase(as_of), puts: puts) == {:ok, report}

    # The empty prefix is the empty ledger's head.
    assert {:ok, %{as_of: %{global_seq: 0, global_hash: nil}, violation_count: 0}} =
             ReleaseTasks.audit_keys(as_of: "0:", puts: puts)

    assert_raise RuntimeError, ~r/key audit refused: :ledger_head_mismatch/, fn ->
      ReleaseTasks.audit_keys(as_of: "#{head.global_seq}:#{hex(<<0::256>>)}", puts: puts)
    end

    for as_of <- ["latest", "#{head.global_seq}x:#{hex(head.global_hash)}", head] do
      assert_raise RuntimeError, ~r/key audit refused: :invalid_ledger_head/, fn ->
        ReleaseTasks.audit_keys(as_of: as_of, puts: puts)
      end
    end
  end

  defp assert_evidence(ref, event, revoked) do
    assert_ref(ref, event)

    if revoked do
      assert_ref(ref.revoked_in, revoked)
    else
      assert ref.revoked_in == nil
    end
  end

  defp assert_ref(ref, event) do
    assert {:ok, hash} = Envelope.event_hash(event)
    assert ref.event_id == event.event_id
    assert ref.event_hash == hex(hash)
    assert ref.global_seq == event.global_seq
    assert ref.chapter_id == event.chapter_id
    assert ref.stream_id == event.stream_id
    assert ref.stream_seq == event.stream_seq
    assert ref.type == event.type
    assert ref.key_id == event.payload["key_id"]
    assert Map.get(ref, :merchant_id) == event.payload["merchant_id"]
    assert Map.get(ref, :tenant_id) == event.payload["tenant_id"]
    assert Map.get(ref, :role) == event.payload["role"]
  end

  # A finding is open while any binding it names is live, and lists one
  # remediation for each live binding's class.
  defp assert_remediation(finding, live) do
    for ref <- [finding.event | finding.earlier_events],
        do: assert(ref.class == class(ref.type, ref[:role]))

    assert finding.open == (live != [])

    assert Enum.sort(Map.keys(finding.remediation)) ==
             Enum.sort(Enum.uniq(Enum.map(live, &class/1)))

    assert Enum.all?(Map.values(finding.remediation), &(is_binary(&1) and &1 != ""))
  end

  defp class(event), do: class(event.type, event.payload["role"])
  defp class("RestaurantDeviceGrantedV1", _), do: :restaurant_device
  defp class("RestaurantDispatchGrantedV1", _), do: :restaurant_dispatch
  defp class("RoleKeyDeclared", "governance"), do: :governance_key
  defp class("RoleKeyDeclared", _), do: :role_key
  defp class("DispatchDispatcherGrantedV1", _), do: :dispatcher
  defp class("ProcurementDispatchRouteV1", _), do: :procurement_route
  defp class("ProcurementOperatorGrantedV1", _), do: :procurement_operator

  # Restore a signed fixture into the fresh test database so the same historical
  # records can be replayed with either the old or the fenced appender.
  defp load_synthetic_history!(events) do
    {records, _head} =
      events
      |> Keyword.values()
      |> Enum.with_index(1)
      |> Enum.map_reduce({nil, %{}}, fn {event, sequence}, {previous_hash, streams} ->
        :ok = Envelope.verify(event)
        {:ok, stream} = Envelope.stream_id(event)
        {stream_seq, stream_hash} = Map.get(streams, stream, {0, nil})

        event =
          Envelope.with_log_assignment(event, %{
            stream_id: stream,
            stream_seq: stream_seq + 1,
            global_seq: sequence,
            prev_global_hash: previous_hash,
            prev_stream_hash: stream_hash
          })

        {:ok, uuid} = ULID.to_uuid(event.event_id)
        bytes = Canonical.encode!(Envelope.full_record_term(event))
        hash = :crypto.hash(:sha256, bytes)

        record = %EventStore.EventData{
          event_id: uuid,
          event_type: event.type,
          data: bytes
        }

        {record, {hash, Map.put(streams, stream, {stream_seq + 1, hash})}}
      end)

    :ok = CoopSubstrate.EventStore.append_to_stream("ledger", :no_stream, records)
    restart_log()
    {:ok, assigned} = Log.read_all()
    events |> Keyword.keys() |> Enum.zip(assigned) |> Map.new()
  end

  defp role(gov, role, id, key, chapter \\ @chapter) do
    signed_event(
      gov,
      "RoleKeyDeclared",
      %{"role" => role, "key_id" => id, "pubkey" => {:bytes, key.signer.pubkey}},
      chapter_id: chapter
    )
  end

  defp device(gov, merchant, id, key) do
    signed_event(gov, "RestaurantDeviceGrantedV1", %{
      "merchant_id" => merchant,
      "device_id" => id,
      "key_id" => id,
      "pubkey" => {:bytes, key.signer.pubkey},
      "actor" => "staff",
      "actions" => ["accept"]
    })
  end

  defp dispatch(gov, merchant, tenant, id, key, chapter \\ @chapter) do
    signed_event(
      gov,
      "RestaurantDispatchGrantedV1",
      %{
        "merchant_id" => merchant,
        "tenant_id" => tenant,
        "key_id" => id,
        "pubkey" => {:bytes, key.signer.pubkey}
      },
      chapter_id: chapter
    )
  end

  defp dispatcher(gov, tenant, id, key) do
    signed_event(gov, "DispatchDispatcherGrantedV1", %{
      "tenant_id" => tenant,
      "dispatcher_id" => "dispatcher-" <> id,
      "key_id" => id,
      "pubkey" => {:bytes, key.signer.pubkey}
    })
  end

  defp route(gov, coop, key, version, active \\ true, chapter \\ @chapter) do
    procurement(gov, "ProcurementDispatchRouteV1", chapter, %{
      "cooperative_id" => coop,
      "tenant_id" => @tenant_a,
      "site" => "North dock",
      "key_id" => "route-" <> coop,
      "pubkey" => {:bytes, key.signer.pubkey},
      "active" => active,
      "expected_version" => version
    })
  end

  defp operator(gov, coop, id, key, version, active \\ true, chapter \\ @chapter) do
    procurement(gov, "ProcurementOperatorGrantedV1", chapter, %{
      "cooperative_id" => coop,
      "operator_id" => id,
      "key_id" => "operator-" <> id,
      "pubkey" => {:bytes, key.signer.pubkey},
      "active" => active,
      "expires_at_ms" => @now + 3_600_000,
      "expected_version" => version
    })
  end

  defp procurement(gov, type, chapter, payload),
    do: signed_event(gov, type, payload, chapter_id: chapter, timestamp_ms: @now)

  defp revoke_role(gov, role, id),
    do: signed_event(gov, "RoleKeyRevoked", %{"role" => role, "key_id" => id})

  defp revoke_grant(gov, merchant, id),
    do:
      signed_event(gov, "RestaurantDeviceRevokedV1", %{"merchant_id" => merchant, "key_id" => id})

  defp hex(data), do: Base.encode16(data, case: :lower)
end
