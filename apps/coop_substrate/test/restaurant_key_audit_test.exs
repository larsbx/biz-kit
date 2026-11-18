defmodule CoopSubstrate.RestaurantKeyAuditTest do
  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.{Canonical, Log, RestaurantKeyAudit, ULID}
  alias CoopSubstrate.Projections.Membership
  alias CoopSubstrate.Protocol.Envelope

  @chapter "chapter-genesis"
  @other_chapter "chapter-two"
  @tenant_a "11111111-1111-1111-1111-111111111111"
  @tenant_b "22222222-2222-2222-2222-222222222222"

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

    for {finding, {rule, later, earlier}} <- Enum.zip(findings, expected) do
      assert finding.rule == rule
      {:bytes, pubkey} = events[later].payload["pubkey"]
      assert finding.pubkey_sha256 == hex(:crypto.hash(:sha256, pubkey))
      assert_evidence(finding.event, events[later], revocations[later])
      assert length(finding.earlier_events) == length(earlier)

      for {ref, name} <- Enum.zip(finding.earlier_events, earlier),
          do: assert_evidence(ref, events[name], revocations[name])
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
    replacement = new_member()

    assert {:ok, _} =
             Log.append([
               role(gov, "governance", gov.signer.key_id, gov),
               role(other_gov, "governance", other_gov.signer.key_id, other_gov, @other_chapter),
               role(gov, "steward", "operator", shared_device),
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
               role(gov, "checkpoint", "outside-dispatch", shared_device),
               device(gov, "third-merchant", "outside-dispatch", shared_device),
               role(gov, "checkpoint", "rotated", shared_dispatch),
               revoke_role(gov, "checkpoint", "rotated"),
               role(gov, "checkpoint", "rotated", replacement),
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

  defp revoke_role(gov, role, id),
    do: signed_event(gov, "RoleKeyRevoked", %{"role" => role, "key_id" => id})

  defp revoke_grant(gov, merchant, id),
    do:
      signed_event(gov, "RestaurantDeviceRevokedV1", %{"merchant_id" => merchant, "key_id" => id})

  defp hex(data), do: Base.encode16(data, case: :lower)
end
