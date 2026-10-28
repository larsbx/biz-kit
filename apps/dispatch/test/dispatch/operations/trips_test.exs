defmodule Dispatch.Operations.TripsTest do
  @moduledoc """
  A participant's own trips, as the field app needs them to share location
  (Section 25.3): which assignment to consent for, and whether a consent
  already covers it — the server's confirmation the reboot rule asks for.
  """

  use ExUnit.Case, async: false

  alias Dispatch.Fleet.Assignment
  alias Dispatch.Operations.{Locations, Trips}
  alias Dispatch.Support.Fixtures

  @moduletag :integration

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dispatch.Repo)

    carrier = Fixtures.carrier()
    tenant = carrier.id
    %{participant: driver} = Fixtures.person(tenant, carrier)
    %{participant: desk} = Fixtures.person(tenant, carrier)

    %{
      tenant: tenant,
      carrier: carrier,
      driver: driver,
      actor: Fixtures.actor(tenant, carrier, driver, "DRIVER"),
      dispatcher: Fixtures.actor(tenant, carrier, desk, "DISPATCHER")
    }
  end

  defp trip(ctx, opts \\ []),
    do: Fixtures.assignment_record(ctx.tenant, ctx.carrier, ctx.driver, opts)

  defp ids(trips), do: Enum.map(trips, & &1.assignment.id)

  test "a participant's trips not yet over, soonest first", ctx do
    now = DateTime.utc_now()
    # Over: completed, cancelled, or past its end. (Completed first: one
    # active trip at a time, Section 22.2.)
    trip(ctx) |> Assignment.activate!() |> Assignment.complete!()
    later = trip(ctx, starts_at: DateTime.add(now, 7_200, :second))
    sooner = trip(ctx, starts_at: DateTime.add(now, -60, :second))
    active = trip(ctx, starts_at: DateTime.add(now, -3_600, :second)) |> Assignment.activate!()
    trip(ctx) |> Ash.Changeset.for_update(:cancel, %{}) |> Ash.update!(authorize?: false)

    trip(ctx,
      starts_at: DateTime.add(now, -7_200, :second),
      ends_at: DateTime.add(now, -60, :second)
    )

    # Someone else's.
    %{participant: other} = Fixtures.person(ctx.tenant, ctx.carrier)
    Fixtures.assignment_record(ctx.tenant, ctx.carrier, other)

    assert {:ok, trips} = Trips.mine(ctx.actor)
    assert ids(trips) == [active.id, sooner.id, later.id]
  end

  test "each trip carries the consent covering it now, and only that", ctx do
    shared = trip(ctx)
    unshared = trip(ctx)
    revoked = trip(ctx)
    {:ok, grant} = Locations.begin_consent(ctx.actor, shared.id)
    {:ok, gone} = Locations.begin_consent(ctx.actor, revoked.id)
    {:ok, _} = Locations.revoke_consent(ctx.actor, gone.id)

    {:ok, trips} = Trips.mine(ctx.actor)
    consent = Map.new(trips, &{&1.assignment.id, &1.consent && &1.consent.id})

    assert consent == %{shared.id => grant.id, unshared.id => nil, revoked.id => nil}
  end

  # The actions stamp an end when a trip completes or is cancelled; a status
  # alone (an import, a correction) still makes it history.
  test "a trip marked over is over, even with no end recorded", ctx do
    for status <- ["COMPLETED", "CANCELLED"] do
      Dispatch.Repo.query!("UPDATE assignments SET status = $1, ends_at = NULL WHERE id = $2", [
        status,
        Ecto.UUID.dump!(trip(ctx).id)
      ])
    end

    assert Trips.mine(ctx.actor) == {:ok, []}
  end

  test "a role without assignment.read.self reads none", ctx do
    trip(ctx)
    assert Trips.mine(ctx.dispatcher) == {:error, :forbidden}
  end
end
