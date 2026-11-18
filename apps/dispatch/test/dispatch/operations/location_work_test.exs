defmodule Dispatch.Operations.LocationWorkTest do
  use ExUnit.Case, async: false

  alias Dispatch.Operations.{Board, LocationDemand, Locations, LocationSnapshot, LocationWork}
  alias Dispatch.Support.Fixtures

  @moduletag :integration

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dispatch.Repo)
    carrier = Fixtures.carrier()
    %{participant: driver} = Fixtures.person(carrier.id, carrier)
    %{participant: desk} = Fixtures.person(carrier.id, carrier)
    driver_actor = Fixtures.actor(carrier.id, carrier, driver, "DRIVER")
    tracker = Fixtures.tracker(carrier.id, carrier, desk)
    load = Fixtures.load(carrier.id, carrier, currency: "USD", agreed_rate_minor: 123_456)
    trip = Fixtures.assignment_record(carrier.id, carrier, driver, load: load)
    {device, seed} = Fixtures.keyed_device(carrier.id, driver)
    {:ok, grant} = Locations.begin_consent(driver_actor, trip.id)

    ctx = %{
      carrier: carrier,
      tenant: carrier.id,
      driver: driver,
      desk: desk,
      driver_actor: driver_actor,
      tracker: tracker,
      trip: trip,
      load: load,
      device: device,
      seed: seed,
      grant: grant
    }

    sample = Fixtures.location_sample(ctx, grant)
    assert {:ok, [%{result: "ACCEPTED"}]} = Locations.ingest(driver_actor, [sample])
    Map.put(ctx, :observation_id, observation_id(ctx))
  end

  defp observation_id(ctx) do
    {:ok, result} = LocationSnapshot.build(ctx.tracker)
    row = Enum.find(result.snapshot.participants, &(&1.participant_id == ctx.driver.id))
    row.position.observation_ref.id
  end

  defp limited_reader(ctx, capabilities) do
    definition =
      Dispatch.Accounts.RoleDefinition
      |> Ash.Changeset.for_create(:seed, %{
        tenant_id: ctx.tenant,
        key: "MAP_#{System.unique_integer([:positive])}",
        label: "Map reader",
        capabilities_json: capabilities,
        profile_module: ctx.tracker.role_assignment.role_definition.profile_module
      })
      |> Ash.create!(authorize?: false, tenant: ctx.tenant)

    Fixtures.actor(ctx.tenant, ctx.carrier, ctx.desk, definition.key,
      definition: definition,
      scope_type: :ORGANIZATION
    )
  end

  test "selected work follows the observation assignment and leaves progress unknown", ctx do
    delivery =
      Fixtures.stop(ctx.tenant, ctx.load, :DELIVERY,
        sequence: 2,
        address_text: "20 Delivery Road",
        contact_phone_e164: "+15551234567"
      )

    pickup =
      Fixtures.stop(ctx.tenant, ctx.load, :PICKUP,
        sequence: 1,
        address_text: "10 Collection Road"
      )

    before =
      Ash.get!(Dispatch.Fleet.Assignment, ctx.trip.id, authorize?: false, tenant: ctx.tenant)

    assert {:ok, work} = LocationWork.fetch(ctx.tracker, ctx.driver.id, ctx.observation_id)
    assert work.scope.key == LocationSnapshot.scope_key(ctx.tracker)
    assert work.participant == %{kind: "participant", id: ctx.driver.id}
    assert work.observation_ref == %{kind: "location_observation", id: ctx.observation_id}
    assert work.assignment.ref == %{kind: "assignment", id: ctx.trip.id}
    assert work.assignment.status == "PLANNED"
    assert work.assignment.vehicle_ref == nil
    assert work.load.ref == %{kind: "load", id: ctx.load.id}
    assert work.load.record_href == "/operations/loads/#{ctx.load.id}"
    assert Enum.map(work.stops, & &1.ref.id) == [pickup.id, delivery.id]
    assert Enum.all?(work.stops, &(&1.position == nil and &1.position_status == "unresolved"))
    assert work.next_stop == %{status: "unknown", reason: "stop_progress_not_recorded"}
    assert work.stop_coverage == %{complete: true, returned: 2, total: 2, limit: 200}
    refute Map.has_key?(work.load, :agreed_rate_minor)
    refute Jason.encode!(work) =~ "+15551234567"
    refute LocationDemand.watched?(ctx.driver.id)

    after_read =
      Ash.get!(Dispatch.Fleet.Assignment, ctx.trip.id, authorize?: false, tenant: ctx.tenant)

    assert {before.status, before.version} == {after_read.status, after_read.version}

    assert %{rows: [[0]]} =
             Dispatch.Repo.query!(
               "SELECT count(*) FROM audit_events WHERE tenant_id = $1 AND subject_id = $2",
               [Ecto.UUID.dump!(ctx.tenant), Ecto.UUID.dump!(ctx.trip.id)]
             )
  end

  test "a visible position does not confer either board-read capability", ctx do
    base = ["operations.participant.read", "operations.location.precise.read"]

    for capabilities <- [base, base ++ ["load.read"], base ++ ["assignment.read"]] do
      reader = limited_reader(ctx, capabilities)
      assert {:ok, result} = LocationSnapshot.build(reader)
      refute result.snapshot.work_access

      assert Enum.any?(
               result.snapshot.participants,
               &(&1.participant_id == ctx.driver.id and &1.position)
             )

      assert LocationWork.fetch(reader, ctx.driver.id, ctx.observation_id) == {:error, :not_found}
    end
  end

  test "changed observations refuse stale work requests", ctx do
    sample =
      Fixtures.location_sample(ctx, ctx.grant, %{
        "occurred_at" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 1, :second)),
        "lat_e7" => 515_200_000
      })

    assert {:ok, [%{result: "ACCEPTED"}]} = Locations.ingest(ctx.driver_actor, [sample])

    assert LocationWork.fetch(ctx.tracker, ctx.driver.id, ctx.observation_id) ==
             {:error, :observation_changed}

    assert {:ok, _} = LocationWork.fetch(ctx.tracker, ctx.driver.id, observation_id(ctx))
  end

  test "consent revocation and renewal cannot recover the old observation's work", ctx do
    {:ok, _} = Locations.revoke_consent(ctx.driver_actor, ctx.grant.id)

    assert LocationWork.fetch(ctx.tracker, ctx.driver.id, ctx.observation_id) ==
             {:error, :not_found}

    {:ok, _} = Locations.begin_consent(ctx.driver_actor, ctx.trip.id)

    assert LocationWork.fetch(ctx.tracker, ctx.driver.id, ctx.observation_id) ==
             {:error, :not_found}
  end

  test "a cached reader loses work immediately when the selected role is revoked", ctx do
    assert {:ok, _} = LocationWork.fetch(ctx.tracker, ctx.driver.id, ctx.observation_id)
    Fixtures.revoke(ctx.tenant, ctx.tracker.role_assignment)

    assert LocationWork.fetch(ctx.tracker, ctx.driver.id, ctx.observation_id) ==
             {:error, :not_found}
  end

  test "work authority is refreshed when capabilities are removed from its definition", ctx do
    Dispatch.Repo.query!(
      "UPDATE role_definitions SET capabilities_json = array_remove(capabilities_json, 'assignment.read') WHERE id = $1 AND tenant_id = $2",
      [
        Ecto.UUID.dump!(ctx.tracker.role_assignment.role_definition_id),
        Ecto.UUID.dump!(ctx.tenant)
      ]
    )

    assert {:ok, result} = LocationSnapshot.build(ctx.tracker)
    refute result.snapshot.work_access

    assert LocationWork.fetch(ctx.tracker, ctx.driver.id, ctx.observation_id) ==
             {:error, :not_found}
  end

  test "foreign participants and malformed identities remain indistinguishable", ctx do
    other = Fixtures.organization(ctx.tenant, :CARRIER)
    %{participant: foreign} = Fixtures.person(ctx.tenant, other)
    elsewhere = Fixtures.carrier()
    %{participant: outside} = Fixtures.person(elsewhere.id, elsewhere)

    for id <- [foreign.id, outside.id, Ecto.UUID.generate(), "not-a-uuid"] do
      assert LocationWork.fetch(ctx.tracker, id, ctx.observation_id) == {:error, :not_found}
    end

    assert LocationWork.fetch(ctx.tracker, ctx.driver.id, "not-a-uuid") == {:error, :not_found}
  end

  test "narrowing the selected scope removes map work and the operator page", ctx do
    assert {:ok, _} = LocationWork.fetch(ctx.tracker, ctx.driver.id, ctx.observation_id)

    Dispatch.Repo.query!(
      "UPDATE role_assignments SET scope_type = 'LOAD', scope_id = $1 WHERE id = $2 AND tenant_id = $3",
      [
        Ecto.UUID.dump!(ctx.load.id),
        Ecto.UUID.dump!(ctx.tracker.role_assignment.id),
        Ecto.UUID.dump!(ctx.tenant)
      ]
    )

    assert LocationWork.fetch(ctx.tracker, ctx.driver.id, ctx.observation_id) ==
             {:error, :not_found}

    assert LocationWork.load(ctx.tracker, ctx.load.id) == {:error, :not_found}
  end

  test "observation binding cannot disclose a load belonging to another carrier", ctx do
    other = Fixtures.organization(ctx.tenant, :CARRIER)
    foreign = Fixtures.load(ctx.tenant, other)

    Dispatch.Repo.query!(
      "UPDATE assignments SET load_id = $1 WHERE id = $2 AND tenant_id = $3",
      [Ecto.UUID.dump!(foreign.id), Ecto.UUID.dump!(ctx.trip.id), Ecto.UUID.dump!(ctx.tenant)]
    )

    assert LocationWork.fetch(ctx.tracker, ctx.driver.id, ctx.observation_id) ==
             {:error, :not_found}
  end

  test "accepted stop geometry is identified as a recorded stop, not a vehicle observation",
       ctx do
    Dispatch.Fleet.Stop
    |> Ash.Changeset.for_create(:add, %{
      tenant_id: ctx.tenant,
      load_id: ctx.load.id,
      sequence: 1,
      kind: :PICKUP,
      address_text: "Recorded depot",
      position: %Geo.Point{coordinates: {-0.12, 51.5}, srid: 4326}
    })
    |> Ash.create!(authorize?: false, tenant: ctx.tenant)

    assert {:ok, work} = LocationWork.fetch(ctx.tracker, ctx.driver.id, ctx.observation_id)
    assert [%{position: %{lat: 51.5, lng: -0.12}, position_status: "recorded"}] = work.stops
  end

  test "current terminal assignment state is preserved during the consent grace window", ctx do
    assert {:ok, _} = Board.transition(ctx.tracker, ctx.trip.id, "activate", ctx.trip.version)
    assert {:ok, _} = Board.transition(ctx.tracker, ctx.trip.id, "complete", ctx.trip.version + 1)
    assert {:ok, work} = LocationWork.fetch(ctx.tracker, ctx.driver.id, ctx.observation_id)
    assert work.assignment.status == "COMPLETED"
    assert work.next_stop.status == "unknown"
  end

  test "the encoded response budget accounts for escaping and returns no partial work", ctx do
    text = String.duplicate("\"", 33_000)
    assert byte_size(text) < LocationWork.response_limit()

    Dispatch.Repo.query!(
      "UPDATE loads SET commodity_text = $1 WHERE id = $2 AND tenant_id = $3",
      [text, Ecto.UUID.dump!(ctx.load.id), Ecto.UUID.dump!(ctx.tenant)]
    )

    assert LocationWork.fetch(ctx.tracker, ctx.driver.id, ctx.observation_id) ==
             {:error, :capacity_exceeded}
  end
end
