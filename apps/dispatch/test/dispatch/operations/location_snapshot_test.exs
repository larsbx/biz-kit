defmodule Dispatch.Operations.LocationSnapshotTest do
  use ExUnit.Case, async: false

  alias Dispatch.Operations.{LocationDemand, Locations, LocationSnapshot}
  alias Dispatch.Support.Fixtures
  alias DispatchWeb.Streams.Locations, as: LocationStream

  @moduletag :integration

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dispatch.Repo)
    carrier = Fixtures.carrier()
    tenant = carrier.id
    %{participant: driver} = Fixtures.person(tenant, carrier, display_name: "Field worker")
    %{participant: desk} = Fixtures.person(tenant, carrier, display_name: "Dispatch desk")
    {device, seed} = Fixtures.keyed_device(tenant, driver)

    %{
      carrier: carrier,
      tenant: tenant,
      driver: driver,
      desk: desk,
      driver_actor: Fixtures.actor(tenant, carrier, driver, "DRIVER"),
      tracker: Fixtures.tracker(tenant, carrier, desk),
      trip: Fixtures.assignment_record(tenant, carrier, driver),
      device: device,
      seed: seed
    }
  end

  defp sharing(ctx, overrides \\ %{}) do
    {:ok, grant} = Locations.begin_consent(ctx.driver_actor, ctx.trip.id)
    sample = Fixtures.location_sample(ctx, grant, overrides)
    assert {:ok, [%{result: "ACCEPTED"}]} = Locations.ingest(ctx.driver_actor, [sample])
    {grant, sample}
  end

  defp row(snapshot, id), do: Enum.find(snapshot.participants, &(&1.participant_id == id))

  defp event(chunk) do
    chunk
    |> IO.iodata_to_binary()
    |> String.split("\n")
    |> Enum.find(&String.starts_with?(&1, "data: "))
    |> String.replace_prefix("data: ", "")
    |> Jason.decode!()
  end

  test "the complete scoped snapshot preserves observation provenance", ctx do
    {_grant, sample} = sharing(ctx, %{"is_mock" => true, "provider" => "test-device"})
    other = Fixtures.organization(ctx.tenant, :CARRIER)
    %{participant: unrelated} = Fixtures.person(ctx.tenant, other)
    elsewhere = Fixtures.carrier()
    %{participant: outside} = Fixtures.person(elsewhere.id, elsewhere)

    assert {:ok, %{snapshot: snapshot, watch_ids: watches}} = LocationSnapshot.build(ctx.tracker)
    assert snapshot.schema_version == 2
    assert snapshot.status == "ok"
    assert snapshot.limit == 200
    assert {:ok, _, _} = DateTime.from_iso8601(snapshot.generated_at)
    assert length(snapshot.participants) == 2
    assert snapshot.scope.key == LocationSnapshot.scope_key(ctx.tracker)
    assert snapshot.scope.organization == %{kind: "organization", id: ctx.carrier.id}
    assert snapshot.query == %{area: "organization", time: "latest"}
    assert snapshot.coordinates == %{crs: "EPSG:4326", units: "degrees", order: "named_lat_lng"}

    assert snapshot.coverage == %{
             population: "active_participants",
             complete: true,
             returned: 2,
             total: 2,
             limit: 200,
             next_cursor: nil
           }

    assert snapshot.work_access
    assert snapshot.source.kind == "dispatch_location_projection"
    assert snapshot.source.revision =~ ~r/^[0-9a-f]{64}$/
    assert snapshot.cursor.sequence == 0
    assert {:ok, _} = Ecto.UUID.cast(snapshot.cursor.stream_id)
    refute row(snapshot, unrelated.id)
    refute row(snapshot, outside.id)
    assert row(snapshot, ctx.desk.id).position == nil
    assert row(snapshot, ctx.driver.id).ref == %{kind: "participant", id: ctx.driver.id}
    assert watches == [ctx.driver.id]

    position = row(snapshot, ctx.driver.id).position
    assert position.lat == 51.5074
    assert position.lng == -0.1278
    assert position.accuracy_m == 12.0
    assert position.provider == "test-device"
    assert position.is_mock
    assert position.observation_ref.kind == "location_observation"
    assert {:ok, _} = Ecto.UUID.cast(position.observation_ref.id)
    assert position.occurred_at == sample["occurred_at"]
    assert {:ok, _, _} = DateTime.from_iso8601(position.received_at)
    refute Map.has_key?(position, :device_id)
    refute Map.has_key?(position, :consent_grant_id)
  end

  test "the selected role must explicitly authorize precise organization reads", ctx do
    sharing(ctx)
    dispatcher = Fixtures.actor(ctx.tenant, ctx.carrier, ctx.desk, "DISPATCHER")
    admin = Fixtures.actor(ctx.tenant, ctx.carrier, ctx.desk, "ADMIN")

    for actor <- [dispatcher, admin, ctx.driver_actor] do
      assert LocationSnapshot.build(actor) == {:error, :not_found}
    end

    Fixtures.revoke(ctx.tenant, ctx.tracker.role_assignment)
    assert LocationSnapshot.build(ctx.tracker) == {:error, :not_found}
  end

  test "new consent does not disclose the sample covered by an old revoked grant", ctx do
    {old, _sample} = sharing(ctx)
    {:ok, _} = Locations.revoke_consent(ctx.driver_actor, old.id)
    {:ok, current} = Locations.begin_consent(ctx.driver_actor, ctx.trip.id)
    refute current.id == old.id

    assert {:ok, result} = LocationSnapshot.build(ctx.tracker)
    assert result.watch_ids == [ctx.driver.id]
    assert row(result.snapshot, ctx.driver.id).position == nil

    sample = Fixtures.location_sample(ctx, current, %{"lat_e7" => 515_100_000})
    assert {:ok, [%{result: "ACCEPTED"}]} = Locations.ingest(ctx.driver_actor, [sample])
    assert {:ok, result} = LocationSnapshot.build(ctx.tracker)
    assert row(result.snapshot, ctx.driver.id).position.lat == 51.51
  end

  test "latest means acquisition time, not upload order", ctx do
    {:ok, grant} = Locations.begin_consent(ctx.driver_actor, ctx.trip.id)
    now = DateTime.utc_now()

    newer =
      Fixtures.location_sample(ctx, grant, %{
        "lat_e7" => 515_200_000,
        "occurred_at" => DateTime.to_iso8601(DateTime.add(now, 1, :second))
      })

    older = Fixtures.location_sample(ctx, grant, %{"occurred_at" => DateTime.to_iso8601(now)})
    assert {:ok, [%{result: "ACCEPTED"}]} = Locations.ingest(ctx.driver_actor, [newer])
    assert {:ok, [%{result: "ACCEPTED"}]} = Locations.ingest(ctx.driver_actor, [older])
    assert {:ok, result} = LocationSnapshot.build(ctx.tracker)
    assert row(result.snapshot, ctx.driver.id).position.lat == 51.52
  end

  test "overflow is explicit and clears every row and demand", ctx do
    sharing(ctx)
    assert {:ok, session, _} = LocationStream.open(ctx.tracker)
    assert LocationDemand.watched?(ctx.driver.id)

    for _ <- 1..(LocationSnapshot.limit() - 1), do: Fixtures.person(ctx.tenant, ctx.carrier)

    assert {:ok, result} = LocationSnapshot.build(ctx.tracker)
    assert result.snapshot.status == "capacity_exceeded"
    assert result.snapshot.participants == []
    assert result.snapshot.coverage.complete == false
    assert result.snapshot.coverage.returned == 0
    assert result.snapshot.coverage.total == nil
    assert result.snapshot.coverage.next_cursor == nil
    assert result.watch_ids == []
    assert {:emit, chunk, _} = LocationStream.tick(session, :refresh)
    assert event(chunk)["status"] == "capacity_exceeded"
    assert event(chunk)["participants"] == []
    refute LocationDemand.watched?(ctx.driver.id)
  end

  test "opening activates demand even before the first sample arrives", ctx do
    {:ok, _grant} = Locations.begin_consent(ctx.driver_actor, ctx.trip.id)
    assert {:ok, session, chunk} = LocationStream.open(ctx.tracker, last_event_id: "old-view")
    assert LocationDemand.watched?(ctx.driver.id)
    assert event(chunk)["status"] == "ok"
    assert IO.iodata_to_binary(chunk) =~ "event: dispatch-locations"
    assert Enum.all?(event(chunk)["participants"], &is_nil(&1["position"]))
    LocationStream.release(session)
    refute LocationDemand.watched?(ctx.driver.id)
  end

  test "consent loss removes coordinates on the next heartbeat without an outbox event", ctx do
    {grant, _sample} = sharing(ctx)
    assert {:ok, session, _} = LocationStream.open(ctx.tracker)
    {:ok, _} = Locations.revoke_consent(ctx.driver_actor, grant.id)

    assert {:emit, chunk, _} = LocationStream.tick(session, :heartbeat)
    assert Enum.all?(event(chunk)["participants"], &is_nil(&1["position"]))
    refute LocationDemand.watched?(ctx.driver.id)
  end

  test "consent expiry removes coordinates and demand without any refresh notification", ctx do
    {grant, _sample} = sharing(ctx)
    assert {:ok, session, _} = LocationStream.open(ctx.tracker)

    grant
    |> Ash.Changeset.for_update(:close_location_consent, %{
      expires_at: DateTime.add(DateTime.utc_now(), -1, :second)
    })
    |> Ash.update!(authorize?: false, tenant: ctx.tenant)

    assert {:emit, chunk, _} = LocationStream.tick(session, :heartbeat)
    assert Enum.all?(event(chunk)["participants"], &is_nil(&1["position"]))
    refute LocationDemand.watched?(ctx.driver.id)
  end

  test "participant suspension removes its row and watch on the next heartbeat", ctx do
    sharing(ctx)
    assert {:ok, session, _} = LocationStream.open(ctx.tracker)

    ctx.driver
    |> Ash.Changeset.for_update(:set_status, %{status: :SUSPENDED})
    |> Ash.update!(authorize?: false, tenant: ctx.tenant)

    assert {:emit, chunk, _} = LocationStream.tick(session, :heartbeat)
    refute Enum.any?(event(chunk)["participants"], &(&1["participant_id"] == ctx.driver.id))
    refute LocationDemand.watched?(ctx.driver.id)
  end

  test "an organization change removes a previously visible participant on the next heartbeat",
       ctx do
    sharing(ctx)
    assert {:ok, session, _} = LocationStream.open(ctx.tracker)
    other = Fixtures.organization(ctx.tenant, :CARRIER)

    # Simulate a committed membership correction without an outbox notification.
    Dispatch.Repo.query!(
      "UPDATE participants SET home_organization_id = $1 WHERE id = $2 AND tenant_id = $3",
      [Ecto.UUID.dump!(other.id), Ecto.UUID.dump!(ctx.driver.id), Ecto.UUID.dump!(ctx.tenant)]
    )

    assert {:emit, chunk, _} = LocationStream.tick(session, :heartbeat)
    refute Enum.any?(event(chunk)["participants"], &(&1["participant_id"] == ctx.driver.id))
    refute LocationDemand.watched?(ctx.driver.id)
  end

  test "a revoked viewer cannot emit another frame or resume its previous stream", ctx do
    sharing(ctx)
    assert {:ok, session, _} = LocationStream.open(ctx.tracker)
    Fixtures.revoke(ctx.tenant, ctx.tracker.role_assignment)

    assert LocationStream.tick(session, :heartbeat) == {:close, :unauthorized}
    assert LocationStream.tick(session, :refresh) == {:close, :unauthorized}
    assert LocationStream.open(ctx.tracker, last_event_id: "old-view") == {:error, :not_found}
    refute LocationDemand.watched?(ctx.driver.id)
  end

  test "cleanup includes watches added after the original session opened", ctx do
    sharing(ctx)
    assert {:ok, initial_session, _} = LocationStream.open(ctx.tracker)
    %{participant: later} = Fixtures.person(ctx.tenant, ctx.carrier)
    later_actor = Fixtures.actor(ctx.tenant, ctx.carrier, later, "DRIVER")
    trip = Fixtures.assignment_record(ctx.tenant, ctx.carrier, later)
    {:ok, _grant} = Locations.begin_consent(later_actor, trip.id)

    assert {:emit, _chunk, _new_session} = LocationStream.tick(initial_session, :refresh)
    assert LocationDemand.watched?(later.id)
    LocationStream.release(initial_session)
    refute LocationDemand.watched?(ctx.driver.id)
    refute LocationDemand.watched?(later.id)
  end

  test "cleanup leaves another request's watches in force", ctx do
    parent = self()

    task =
      Task.async(fn ->
        LocationDemand.watch(ctx.driver.id)
        send(parent, :other_request_watching)

        receive do
          :finish -> LocationDemand.release_watches()
        end
      end)

    assert_receive :other_request_watching
    LocationDemand.watch(ctx.driver.id)
    LocationDemand.release_watches()
    assert LocationDemand.watched?(ctx.driver.id)
    send(task.pid, :finish)
    Task.await(task)
    refute LocationDemand.watched?(ctx.driver.id)
  end

  test "content revision is stable while GET lifetimes are always fresh", ctx do
    {grant, _} = sharing(ctx)
    assert {:ok, first} = LocationSnapshot.build(ctx.tracker)
    assert {:ok, second} = LocationSnapshot.build(ctx.tracker)
    assert first.snapshot.source.revision == second.snapshot.source.revision
    refute first.snapshot.cursor.stream_id == second.snapshot.cursor.stream_id
    assert first.snapshot.cursor.sequence == second.snapshot.cursor.sequence

    {:ok, _} = Locations.revoke_consent(ctx.driver_actor, grant.id)
    assert {:ok, revoked} = LocationSnapshot.build(ctx.tracker)
    refute first.snapshot.source.revision == revoked.snapshot.source.revision
  end

  test "SSE sequences increase and reconnect starts a new zero-based lifetime", ctx do
    sharing(ctx)
    assert {:ok, session, initial} = LocationStream.open(ctx.tracker, last_event_id: "stale:777")
    initial = event(initial)
    assert initial["cursor"]["sequence"] == 0
    assert {:emit, first, session} = LocationStream.tick(session, :refresh)
    assert {:emit, second, session} = LocationStream.tick(session, :heartbeat)
    assert event(first)["cursor"]["sequence"] == 1
    assert event(second)["cursor"]["sequence"] == 2
    assert event(second)["cursor"]["stream_id"] == initial["cursor"]["stream_id"]
    LocationStream.release(session)

    assert {:ok, resumed, fresh} = LocationStream.open(ctx.tracker, last_event_id: "stale:777")
    assert event(fresh)["cursor"]["sequence"] == 0
    refute event(fresh)["cursor"]["stream_id"] == initial["cursor"]["stream_id"]
    LocationStream.release(resumed)
  end

  test "scope identity binds the selected authority rather than its cached time", ctx do
    assert LocationSnapshot.scope_key(ctx.tracker) ==
             LocationSnapshot.scope_key(%{ctx.tracker | at: DateTime.add(ctx.tracker.at, 1)})

    for changed <- [
          %{ctx.tracker | tenant_id: Ecto.UUID.generate()},
          %{ctx.tracker | principal_id: Ecto.UUID.generate()},
          %{ctx.tracker | principal_type: :SERVICE},
          %{
            ctx.tracker
            | role_assignment: %{ctx.tracker.role_assignment | id: Ecto.UUID.generate()}
          },
          %{
            ctx.tracker
            | role_assignment: %{
                ctx.tracker.role_assignment
                | organization_id: Ecto.UUID.generate()
              }
          }
        ] do
      refute LocationSnapshot.scope_key(ctx.tracker) == LocationSnapshot.scope_key(changed)
    end
  end

  test "a malformed stored uncertainty cannot leave the checked presentation boundary", ctx do
    sharing(ctx)

    Dispatch.Repo.query!(
      "UPDATE location_samples SET accuracy_m = -1 WHERE participant_id = $1 AND tenant_id = $2",
      [Ecto.UUID.dump!(ctx.driver.id), Ecto.UUID.dump!(ctx.tenant)]
    )

    assert {:ok, result} = LocationSnapshot.build(ctx.tracker)
    assert row(result.snapshot, ctx.driver.id).position == nil
  end

  test "a stream cannot migrate away from its originally bound scope", ctx do
    sharing(ctx)
    assert {:ok, session, _} = LocationStream.open(ctx.tracker)
    assert LocationDemand.watched?(ctx.driver.id)
    # The page-bound scope is immutable even if a future adapter hands the
    # stream a different fresh actor. Refuse before synchronizing any demand.
    stale_binding = %{session | scope_key: String.duplicate("0", 64)}
    assert LocationStream.tick(stale_binding, :heartbeat) == {:close, :unauthorized}
    refute LocationDemand.watched?(ctx.driver.id)
  end

  test "oversized roster text clears the entire snapshot and existing watches", ctx do
    sharing(ctx)
    assert {:ok, session, _} = LocationStream.open(ctx.tracker)
    assert LocationDemand.watched?(ctx.driver.id)

    Dispatch.Repo.query!(
      "UPDATE participants SET public_name = $1 WHERE id = $2 AND tenant_id = $3",
      [
        String.duplicate("x", LocationSnapshot.response_limit()),
        Ecto.UUID.dump!(ctx.driver.id),
        Ecto.UUID.dump!(ctx.tenant)
      ]
    )

    assert {:ok, %{snapshot: snapshot, watch_ids: []}} = LocationSnapshot.build(ctx.tracker)
    assert snapshot.status == "capacity_exceeded"
    assert snapshot.participants == []
    refute snapshot.coverage.complete
    assert byte_size(Jason.encode!(snapshot)) <= LocationSnapshot.response_limit()
    assert {:emit, chunk, _} = LocationStream.tick(session, :heartbeat)
    assert event(chunk)["status"] == "capacity_exceeded"
    refute LocationDemand.watched?(ctx.driver.id)
  end
end
