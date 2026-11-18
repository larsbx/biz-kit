defmodule Dispatch.Operations.EquipmentExclusivityConcurrencyTest do
  @moduledoc """
  Two independently committed sessions activate trips that share one vehicle.
  The second activation queues on the first's uncommitted unique-index entry
  and, once the first commits, is refused: at most one ACTIVE trip per
  vehicle (formal/quint/obligations/dispatch.qnt).
  """
  use ExUnit.Case, async: false

  import Dispatch.Support.ConcurrentSessions, only: [session: 1, backend: 0, waiting_on?: 1]

  alias Dispatch.Fleet.{Assignment, Vehicle}
  alias Dispatch.Operations.Board
  alias Dispatch.Repo
  alias Dispatch.Support.{ConcurrentSessions, Fixtures}
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :integration

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    org = Fixtures.carrier()
    people = for name <- ~w(Desk Dana Ola), do: Fixtures.person(org.id, org, display_name: name)
    [desk, dana, ola] = Enum.map(people, & &1.participant)
    for driver <- [dana, ola], do: Fixtures.assignment(org.id, org, driver, "DRIVER")
    dispatcher = Fixtures.actor(org.id, org, desk, "DISPATCHER")
    on_exit(fn -> ConcurrentSessions.cleanup(org, Enum.map(people, & &1.user)) end)

    truck = Fixtures.equipment(org.id, org, Vehicle)

    [a, b] =
      for driver <- [dana, ola] do
        {:ok, load} = Board.create_load(dispatcher, %{})

        {:ok, %{assignments: [trip]}} =
          Board.plan(dispatcher, load.id, %{
            "operator_participant_id" => driver.id,
            "vehicle_id" => truck.id
          })

        trip
      end

    %{org: org, dispatcher: dispatcher, a: a, b: b}
  end

  test "of two concurrent activations sharing a vehicle, exactly one commits", ctx do
    parent = self()

    holder =
      session(fn ->
        Repo.transaction(fn ->
          {:ok, _} = Board.transition(ctx.dispatcher, ctx.a.id, "activate", ctx.a.version)
          send(parent, {:holding, backend()})
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive {:holding, holder_backend}, 5_000

    requester =
      session(fn -> Board.transition(ctx.dispatcher, ctx.b.id, "activate", ctx.b.version) end)

    try do
      assert waiting_on?(holder_backend), "the second activation must queue on the first"
    after
      send(holder.pid, :release)
    end

    assert {:ok, :ok} = Task.await(holder, 10_000)
    assert {:error, {:invalid, message}} = Task.await(requester, 10_000)
    assert message =~ "vehicle"
    assert statuses(ctx) == [:ACTIVE, :PLANNED]
  end

  defp statuses(ctx) do
    for trip <- [ctx.a, ctx.b],
        do: Ash.get!(Assignment, trip.id, authorize?: false, tenant: ctx.org.id).status
  end
end
