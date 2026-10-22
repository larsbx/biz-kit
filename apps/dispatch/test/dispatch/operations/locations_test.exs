defmodule Dispatch.Operations.LocationsTest do
  @moduledoc "Consented location sharing: Sections 6.1, 24.2 and acceptance criterion 4."

  use ExUnit.Case, async: false

  require Ash.Query

  alias Dispatch.Operations.{LocationSample, Locations}
  alias Dispatch.Support.Fixtures

  @moduletag :integration

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dispatch.Repo)

    carrier = Fixtures.carrier()
    tenant = carrier.id
    %{participant: driver} = Fixtures.person(tenant, carrier)
    actor = Fixtures.actor(tenant, carrier, driver, "DRIVER")
    {device, seed} = Fixtures.keyed_device(tenant, driver)
    trip = Fixtures.assignment_record(tenant, carrier, driver)

    %{
      tenant: tenant,
      carrier: carrier,
      driver: driver,
      actor: actor,
      device: device,
      seed: seed,
      trip: trip
    }
  end

  defp sample(ctx, grant, overrides \\ %{}) do
    %{
      "sample_id" => Ash.UUID.generate(),
      "assignment_id" => ctx.trip.id,
      "lat_e7" => 515_074_000,
      "lng_e7" => -1_278_000,
      "accuracy_cm" => 1_200,
      "provider" => "fused",
      "is_mock" => false,
      "occurred_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "device_id" => ctx.device.id,
      "device_sequence" => System.unique_integer([:positive]),
      "consent_grant_id" => grant.id
    }
    |> Map.merge(overrides)
    |> Fixtures.signed_sample(ctx.seed)
  end

  defp results(ctx, samples) do
    {:ok, results} = Locations.ingest(ctx.actor, samples)
    Enum.map(results, &{&1.result, &1.code})
  end

  describe "consent" do
    test "is begun for one's own trip, once, and ends with the trip plus grace", ctx do
      assert {:ok, grant} = Locations.begin_consent(ctx.actor, ctx.trip.id)
      assert grant.scope_json["assignment_id"] == ctx.trip.id
      assert {:ok, %{id: same}} = Locations.begin_consent(ctx.actor, ctx.trip.id)
      assert same == grant.id

      ends_at = DateTime.add(DateTime.utc_now(), 3_600, :second)
      bounded = Fixtures.assignment_record(ctx.tenant, ctx.carrier, ctx.driver, ends_at: ends_at)
      {:ok, window} = Locations.begin_consent(ctx.actor, bounded.id)
      assert window.expires_at == DateTime.add(ends_at, 1_800, :second)

      %{participant: other} = Fixtures.person(ctx.tenant, ctx.carrier)
      theirs = Fixtures.assignment_record(ctx.tenant, ctx.carrier, other)
      assert Locations.begin_consent(ctx.actor, theirs.id) == {:error, :not_found}
    end

    test "needs location.share.self", ctx do
      %{participant: desk} = Fixtures.person(ctx.tenant, ctx.carrier)
      dispatcher = Fixtures.actor(ctx.tenant, ctx.carrier, desk, "DISPATCHER")

      assert Locations.begin_consent(dispatcher, ctx.trip.id) == {:error, :forbidden}
      assert Locations.ingest(dispatcher, []) == {:error, :forbidden}
    end
  end

  describe "ingest" do
    test "accepts a signed sample under consent, stored as geography with its measures", ctx do
      {:ok, grant} = Locations.begin_consent(ctx.actor, ctx.trip.id)
      body = sample(ctx, grant, %{"speed_cmps" => 1_250, "bearing_cdeg" => 9_000})

      assert results(ctx, [body]) == [{"ACCEPTED", nil}]

      {:ok, stored} = LocationSample.latest(ctx.driver.id, actor: ctx.actor, tenant: ctx.tenant)
      assert stored.id == body["sample_id"]
      assert stored.position.coordinates == {-0.1278, 51.5074}
      assert stored.position.srid == 4326
      assert {stored.accuracy_m, stored.speed_mps, stored.bearing_deg} == {12.0, 12.5, 90.0}
    end

    test "judges each sample on its own and keeps the batch's order", ctx do
      {:ok, grant} = Locations.begin_consent(ctx.actor, ctx.trip.id)
      good = sample(ctx, grant)
      unsigned = good |> Map.delete("device_signature") |> Map.put("device_sequence", 99_999)
      tampered = sample(ctx, grant) |> Map.put("lat_e7", 1)
      # Floats have no canonical form: a client that sends one cannot have signed it.
      malformed = sample(ctx, grant) |> Map.put("lat_e7", 51.5)

      assert results(ctx, [good, unsigned, tampered, malformed]) == [
               {"ACCEPTED", nil},
               {"REJECTED", "DEVICE_SIGNATURE_REQUIRED"},
               {"REJECTED", "DEVICE_SIGNATURE_INVALID"},
               {"REJECTED", "INVALID_SAMPLE"}
             ]
    end

    test "a retried sample is a duplicate; its sequence carrying another is refused", ctx do
      {:ok, grant} = Locations.begin_consent(ctx.actor, ctx.trip.id)
      body = sample(ctx, grant)
      reused = sample(ctx, grant, %{"device_sequence" => body["device_sequence"]})

      assert results(ctx, [body, body, reused]) == [
               {"ACCEPTED", nil},
               {"DUPLICATE", nil},
               {"REJECTED", "DEVICE_SEQUENCE_CONFLICT"}
             ]
    end

    test "the revocation race: acquired before revocation is kept, after is refused", ctx do
      {:ok, grant} = Locations.begin_consent(ctx.actor, ctx.trip.id)
      before_revoking = sample(ctx, grant)
      Process.sleep(5)
      {:ok, _revoked} = Locations.revoke_consent(ctx.actor, grant.id)
      after_revoking = sample(ctx, grant)

      assert results(ctx, [before_revoking, after_revoking]) == [
               {"ACCEPTED", nil},
               {"REJECTED", "REJECTED_CONSENT"}
             ]
    end

    test "consent covers its own trip, from its grant, and not a future clock", ctx do
      {:ok, grant} = Locations.begin_consent(ctx.actor, ctx.trip.id)
      other_trip = Fixtures.assignment_record(ctx.tenant, ctx.carrier, ctx.driver)
      earlier = DateTime.add(grant.granted_at, -60, :second) |> DateTime.to_iso8601()
      future = DateTime.utc_now() |> DateTime.add(600, :second) |> DateTime.to_iso8601()

      assert results(ctx, [
               sample(ctx, grant, %{"assignment_id" => other_trip.id}),
               sample(ctx, grant, %{"occurred_at" => earlier}),
               sample(ctx, grant, %{"occurred_at" => future}),
               sample(ctx, grant, %{"consent_grant_id" => Ash.UUID.generate()})
             ]) == [
               {"REJECTED", "REJECTED_CONSENT"},
               {"REJECTED", "REJECTED_CONSENT"},
               {"REJECTED", "CLOCK_SKEW"},
               {"REJECTED", "REJECTED_CONSENT"}
             ]
    end

    test "at most a hundred samples a batch", ctx do
      assert Locations.ingest(ctx.actor, List.duplicate(%{}, 101)) == {:error, :batch_too_large}
    end
  end
end
