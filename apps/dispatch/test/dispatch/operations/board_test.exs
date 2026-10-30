defmodule Dispatch.Operations.BoardTest do
  @moduledoc """
  The carrier's dispatch board: a dispatcher works its own organization's
  loads, stops and trips, sees nothing of another carrier's, and every write
  leaves an audit event.
  """

  use ExUnit.Case, async: false

  require Ash.Query

  alias Dispatch.Audit.AuditEvent
  alias Dispatch.Fleet.Vehicle
  alias Dispatch.Operations.Board
  alias Dispatch.Support.Fixtures

  @moduletag :integration

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dispatch.Repo)

    carrier = Fixtures.carrier()
    tenant = carrier.id
    %{participant: driver} = Fixtures.person(tenant, carrier, display_name: "Dana")
    %{participant: desk} = Fixtures.person(tenant, carrier, display_name: "Desk")
    driver_role = Fixtures.assignment(tenant, carrier, driver, "DRIVER")

    %{
      tenant: tenant,
      carrier: carrier,
      driver: driver,
      driver_role: driver_role,
      dispatcher: Fixtures.actor(tenant, carrier, desk, "DISPATCHER")
    }
  end

  defp vehicle(ctx, org \\ nil) do
    Vehicle
    |> Ash.Changeset.for_create(:register, %{
      tenant_id: ctx.tenant,
      organization_id: (org || ctx.carrier).id,
      unit_number: Fixtures.unique("TRUCK"),
      status: :ACTIVE
    })
    |> Ash.create!(authorize?: false, tenant: ctx.tenant)
  end

  defp audit_types(ctx) do
    AuditEvent
    |> Ash.Query.filter(actor_id == ^ctx.dispatcher.principal_id)
    |> Ash.read!(authorize?: false, tenant: ctx.tenant)
    |> Enum.map(& &1.event_type)
    |> Enum.sort()
  end

  test "a load is created, stopped, planned and run end to end", ctx do
    truck = vehicle(ctx)

    assert {:ok, load} =
             Board.create_load(ctx.dispatcher, %{
               "external_reference" => "PO-1",
               "commodity_text" => "Pallets"
             })

    assert load.status == :DRAFT
    assert load.carrier_organization_id == ctx.carrier.id

    assert {:ok, load} =
             Board.add_stop(ctx.dispatcher, load.id, %{
               "kind" => "PICKUP",
               "address_text" => "1 Dock Rd"
             })

    assert {:ok, load} =
             Board.add_stop(ctx.dispatcher, load.id, %{
               "kind" => "DELIVERY",
               "address_text" => "2 Yard Ln"
             })

    assert Enum.map(load.stops, &{&1.sequence, &1.kind}) == [{1, :PICKUP}, {2, :DELIVERY}]

    assert {:ok, load} =
             Board.plan(ctx.dispatcher, load.id, %{
               "operator_participant_id" => ctx.driver.id,
               "vehicle_id" => truck.id
             })

    [trip] = load.assignments
    assert {trip.status, trip.vehicle_id} == {:PLANNED, truck.id}
    # Derived from the driver's own role, never asserted by the dispatcher.
    assert trip.operator_exclusive

    assert {:ok, load} = Board.transition(ctx.dispatcher, trip.id, "activate", trip.version)
    [trip] = load.assignments
    assert trip.status == :ACTIVE

    assert {:ok, load} = Board.transition(ctx.dispatcher, trip.id, "complete", trip.version)
    assert [%{status: :COMPLETED}] = load.assignments

    assert audit_types(ctx) ==
             ~w(assignment.activated assignment.completed assignment.planned
                load.created stop.added stop.added)
  end

  for source <- [:PLANNED, :ACTIVE, :COMPLETED, :CANCELLED],
      action <- ["activate", "complete", "cancel"] do
    @source source
    @action action
    test "#{action} from #{source} follows the transition table", ctx do
      trip = Fixtures.assignment_record(ctx.tenant, ctx.carrier, ctx.driver)

      trip =
        case @source do
          :PLANNED -> trip
          :ACTIVE -> move(ctx, trip, "activate")
          :COMPLETED -> ctx |> move(trip, "activate") |> then(&move(ctx, &1, "complete"))
          :CANCELLED -> move(ctx, trip, "cancel")
        end

      before_audit = audit_types(ctx)
      allowed =
        {@source, @action} in [
          {:PLANNED, "activate"},
          {:PLANNED, "cancel"},
          {:ACTIVE, "complete"},
          {:ACTIVE, "cancel"}
        ]

      if allowed do
        moved = move(ctx, trip, @action)
        assert moved.version == trip.version + 1
        assert moved.status ==
                 %{"activate" => :ACTIVE, "complete" => :COMPLETED, "cancel" => :CANCELLED}[@action]
        assert length(audit_types(ctx)) == length(before_audit) + 1
      else
        for version <- [trip.version, nil] do
          assert {:error, {:invalid, _}} =
                   Board.transition(ctx.dispatcher, trip.id, @action, version)
        end

        {:ok, %{assignments: [unchanged]}} = Board.load(ctx.dispatcher, trip.load_id)
        assert {unchanged.status, unchanged.ends_at, unchanged.version} ==
                 {trip.status, trip.ends_at, trip.version}
        assert audit_types(ctx) == before_audit
      end
    end
  end

  defp move(ctx, trip, action) do
    assert {:ok, %{assignments: [moved]}} =
             Board.transition(ctx.dispatcher, trip.id, action, trip.version)

    moved
  end

  test "a transition increments the version and rejects a stale retry", ctx do
    trip = Fixtures.assignment_record(ctx.tenant, ctx.carrier, ctx.driver)
    moved = move(ctx, trip, "activate")
    assert moved.version == trip.version + 1
    assert {:error, :stale} = Board.transition(ctx.dispatcher, trip.id, "cancel", trip.version)
    assert {:ok, %{assignments: [%{status: :ACTIVE}]}} = Board.load(ctx.dispatcher, trip.load_id)
  end

  test "a foreign organization's trip cannot be transitioned", ctx do
    other = Fixtures.organization(ctx.tenant, :CARRIER)
    trip = Fixtures.assignment_record(ctx.tenant, other, ctx.driver)
    assert {:error, :not_found} =
             Board.transition(ctx.dispatcher, trip.id, "activate", trip.version)

    assert {:error, :not_found} = Board.transition(ctx.dispatcher, trip.id, "cancel", nil)
  end

  test "a stale version is refused and changes nothing", ctx do
    {:ok, load} = Board.create_load(ctx.dispatcher, %{"commodity_text" => "Steel"})

    assert {:error, :stale} =
             Board.update_load(ctx.dispatcher, load.id, %{
               "commodity_text" => "Copper",
               "expected_version" => load.version + 1
             })

    assert {:ok, %{commodity_text: "Steel"}} = Board.load(ctx.dispatcher, load.id)
  end

  test "another carrier's load, driver and truck are not found", ctx do
    other = Fixtures.organization(ctx.tenant, :CARRIER)
    theirs = Fixtures.load(ctx.tenant, other)
    %{participant: stranger} = Fixtures.person(ctx.tenant, other)
    Fixtures.assignment(ctx.tenant, other, stranger, "DRIVER")
    their_truck = vehicle(ctx, other)

    assert {:error, :not_found} = Board.load(ctx.dispatcher, theirs.id)

    assert {:error, :not_found} =
             Board.add_stop(ctx.dispatcher, theirs.id, %{
               "kind" => "PICKUP",
               "address_text" => "x"
             })

    {:ok, ours} = Board.create_load(ctx.dispatcher, %{})

    assert {:error, {:invalid, _}} =
             Board.plan(ctx.dispatcher, ours.id, %{"operator_participant_id" => stranger.id})

    assert {:error, {:invalid, _}} =
             Board.plan(ctx.dispatcher, ours.id, %{
               "operator_participant_id" => ctx.driver.id,
               "vehicle_id" => their_truck.id
             })

    {:ok, loads} = Board.loads(ctx.dispatcher)
    assert Enum.map(loads, & &1.id) == [ours.id]

    {:ok, fleet} = Board.fleet(ctx.dispatcher)
    assert Enum.map(fleet.drivers, & &1.id) == [ctx.driver.id]
    assert fleet.vehicles == []
  end

  test "a driver cannot work the board", ctx do
    {:ok, driver} = Dispatch.Access.Actor.from_assignment(ctx.driver_role)

    assert {:error, :forbidden} = Board.loads(driver)
    assert {:error, :forbidden} = Board.create_load(driver, %{})
    assert {:error, :forbidden} = Board.fleet(driver)
  end

  test "a second active trip for one driver is refused", ctx do
    {:ok, first} = Board.create_load(ctx.dispatcher, %{})
    {:ok, second} = Board.create_load(ctx.dispatcher, %{})
    plan = %{"operator_participant_id" => ctx.driver.id}

    {:ok, %{assignments: [a]}} = Board.plan(ctx.dispatcher, first.id, plan)
    {:ok, %{assignments: [b]}} = Board.plan(ctx.dispatcher, second.id, plan)
    {:ok, _} = Board.transition(ctx.dispatcher, a.id, "activate", a.version)

    assert {:error, {:invalid, _}} = Board.transition(ctx.dispatcher, b.id, "activate", b.version)
  end
end
