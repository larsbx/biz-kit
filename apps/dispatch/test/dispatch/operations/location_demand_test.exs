defmodule Dispatch.Operations.LocationDemandTest do
  @moduledoc "Who may watch a position, and how a device hears of it."

  use ExUnit.Case, async: false

  alias Dispatch.Operations.{LocationDemand, Locations}
  alias Dispatch.Support.Fixtures

  @moduletag :integration

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dispatch.Repo)

    carrier = Fixtures.carrier()
    tenant = carrier.id
    %{participant: driver} = Fixtures.person(tenant, carrier)
    driver_actor = Fixtures.actor(tenant, carrier, driver, "DRIVER")
    trip = Fixtures.assignment_record(tenant, carrier, driver)

    %{participant: desk} = Fixtures.person(tenant, carrier)
    dispatcher = Fixtures.actor(tenant, carrier, desk, "DISPATCHER")

    tracker = Fixtures.tracker(tenant, carrier, desk)

    %{
      tenant: tenant,
      carrier: carrier,
      driver: driver,
      driver_actor: driver_actor,
      trip: trip,
      dispatcher: dispatcher,
      tracker: tracker
    }
  end

  test "precise reading needs the capability, the organization, and consent active now", ctx do
    refute LocationDemand.precise?(ctx.tracker, ctx.driver.id)

    {:ok, grant} = Locations.begin_consent(ctx.driver_actor, ctx.trip.id)
    assert LocationDemand.precise?(ctx.tracker, ctx.driver.id)
    refute LocationDemand.precise?(ctx.dispatcher, ctx.driver.id)

    elsewhere = Fixtures.carrier()
    %{participant: stranger} = Fixtures.person(ctx.tenant, elsewhere)
    refute LocationDemand.precise?(ctx.tracker, stranger.id)

    {:ok, _} = Locations.revoke_consent(ctx.driver_actor, grant.id)
    refute LocationDemand.precise?(ctx.tracker, ctx.driver.id)
  end

  test "a device hears of the first watcher and of the last leaving, and of exits", ctx do
    participant = ctx.driver.id
    {ref, watched?} = LocationDemand.monitor(participant)
    refute watched?

    viewer = spawn_watcher(participant)
    assert_receive {^ref, :join, _group, [^viewer]}
    assert LocationDemand.watched?(participant)

    # The viewer's process ending is the leaving; nothing must remember to.
    Process.exit(viewer, :kill)
    assert_receive {^ref, :leave, _group, [^viewer]}
    refute LocationDemand.watched?(participant)

    LocationDemand.demonitor(ref)
  end

  test "watching twice is one watch", ctx do
    :ok = LocationDemand.watch(ctx.driver.id)
    :ok = LocationDemand.watch(ctx.driver.id)
    :ok = LocationDemand.unwatch(ctx.driver.id)
    refute LocationDemand.watched?(ctx.driver.id)
  end

  test "the device's two modes come from configuration" do
    assert %{"mode" => "realtime", "sample_interval_ms" => 3_000, "upload_interval_ms" => 0} =
             LocationDemand.policy(:realtime)

    assert %{"mode" => "trickle", "sample_interval_ms" => 120_000} =
             LocationDemand.policy(:trickle)
  end

  defp spawn_watcher(participant) do
    parent = self()

    pid =
      spawn(fn ->
        LocationDemand.watch(participant)
        send(parent, :watching)
        Process.sleep(:infinity)
      end)

    assert_receive :watching
    pid
  end
end
