defmodule DispatchWeb.Streams.LocationDemandTest do
  @moduledoc """
  What a sharing device hears: realtime while a precise reader watches, trickle
  otherwise, and nothing at all once it stops sharing. Driven a tick at a time,
  with the `:pg` notifications the transport would hand over.
  """

  use ExUnit.Case, async: false

  alias Dispatch.Operations.Locations
  alias Dispatch.Support.Fixtures
  alias DispatchWeb.Streams.{LocationDemand, Participant}

  @moduletag :integration

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dispatch.Repo)

    carrier = Fixtures.carrier()
    tenant = carrier.id
    %{participant: driver} = Fixtures.person(tenant, carrier)
    %{participant: desk} = Fixtures.person(tenant, carrier)
    driver_actor = Fixtures.actor(tenant, carrier, driver, "DRIVER")
    trip = Fixtures.assignment_record(tenant, carrier, driver)

    %{
      driver: driver,
      driver_actor: driver_actor,
      trip: trip,
      dispatcher: Fixtures.actor(tenant, carrier, desk, "DISPATCHER"),
      tracker: Fixtures.tracker(tenant, carrier, desk)
    }
  end

  defp consent(ctx) do
    {:ok, grant} = Locations.begin_consent(ctx.driver_actor, ctx.trip.id)
    grant
  end

  # A viewer's stream, in a process of its own as in production.
  defp viewing(actor, participant_id) do
    parent = self()

    pid =
      spawn(fn ->
        Ecto.Adapters.SQL.Sandbox.allow(Dispatch.Repo, parent, self())
        {:ok, _session, _snapshot} = Participant.open(actor, participant_id)
        send(parent, :viewing)
        Process.sleep(:infinity)
      end)

    assert_receive :viewing, 5_000
    pid
  end

  defp heard(chunk), do: IO.iodata_to_binary(chunk)

  test "nothing is heard while nothing is shared", ctx do
    assert LocationDemand.open(ctx.driver_actor) == {:error, :not_found}
  end

  test "opens in trickle, turns realtime for a precise reader, and back when they leave", ctx do
    consent(ctx)
    {:ok, session, snapshot} = LocationDemand.open(ctx.driver_actor)
    assert heard(snapshot) =~ ~s(event: location-demand\ndata: {"mode":"trickle")

    viewer = viewing(ctx.tracker, ctx.driver.id)
    ref = session.ref
    assert_receive {^ref, :join, _group, [^viewer]}
    {:emit, chunk, session} = LocationDemand.tick(session, :demand)
    assert heard(chunk) =~ ~s("mode":"realtime")
    assert heard(chunk) =~ ~s("sample_interval_ms":3000)

    # A second notification with no change sends nothing.
    assert {:emit, [], ^session} = LocationDemand.tick(session, :demand)

    Process.exit(viewer, :kill)
    assert_receive {^ref, :leave, _group, [^viewer]}
    {:emit, chunk, session} = LocationDemand.tick(session, :demand)
    assert heard(chunk) =~ ~s("mode":"trickle")

    LocationDemand.release(session)
  end

  test "a reader without precise location is no demand", ctx do
    consent(ctx)
    {:ok, session, _snapshot} = LocationDemand.open(ctx.driver_actor)

    viewing(ctx.dispatcher, ctx.driver.id)
    refute_receive {_ref, :join, _group, _pids}
    assert {:emit, [], _session} = LocationDemand.tick(session, :demand)

    LocationDemand.release(session)
  end

  test "a reader already watching makes the stream open in realtime", ctx do
    consent(ctx)
    viewing(ctx.tracker, ctx.driver.id)

    {:ok, session, snapshot} = LocationDemand.open(ctx.driver_actor)
    assert heard(snapshot) =~ ~s("mode":"realtime")
    LocationDemand.release(session)
  end

  test "revoking consent closes the stream at the next tick", ctx do
    grant = consent(ctx)
    {:ok, session, _snapshot} = LocationDemand.open(ctx.driver_actor)
    {:emit, beat, session} = LocationDemand.tick(session, :heartbeat)
    assert heard(beat) =~ ": heartbeat"

    {:ok, _} = Locations.revoke_consent(ctx.driver_actor, grant.id)
    assert LocationDemand.tick(session, :demand) == {:close, :unauthorized}
    assert LocationDemand.tick(session, :refresh) == {:close, :unauthorized}
    assert LocationDemand.tick(session, :heartbeat) == {:close, :unauthorized}

    LocationDemand.release(session)
  end
end
