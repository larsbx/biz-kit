defmodule Dispatch.Operations.BoardConcurrencyTest do
  use ExUnit.Case, async: false

  import Dispatch.Support.ConcurrentSessions,
    only: [session: 1, backend: 0, lock_trip: 1, waiting_on?: 1]

  alias Dispatch.Fleet.Assignment
  alias Dispatch.Operations.Board
  alias Dispatch.Repo
  alias Dispatch.Support.{ConcurrentSessions, Fixtures}
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :integration

  setup do
    # Separate committed sessions are essential: sharing a sandbox connection
    # serializes calls in the test harness and cannot demonstrate a row lock.
    :ok = Sandbox.checkout(Repo, sandbox: false)
    org = Fixtures.carrier()
    %{user: user, participant: driver} = Fixtures.person(org.id, org)
    actor = Fixtures.actor(org.id, org, driver, "DISPATCHER")
    trip = Fixtures.assignment_record(org.id, org, driver)

    on_exit(fn -> ConcurrentSessions.cleanup(org, [user]) end)

    %{actor: actor, trip: trip}
  end

  for versioned <- [true, false] do
    @versioned versioned
    test "a queued transition rechecks the committed state (versioned=#{versioned})", ctx do
      parent = self()

      holder =
        session(fn ->
          Repo.transaction(fn ->
            lock_trip(ctx.trip)
            {:ok, load} = Board.transition(ctx.actor, ctx.trip.id, "cancel", ctx.trip.version)
            send(parent, {:holding, backend(), load})
            receive do: (:commit -> load)
          end)
        end)

      assert_receive {:holding, backend, cancelled}, 5_000
      expected = if @versioned, do: ctx.trip.version, else: nil

      requester =
        session(fn -> Board.transition(ctx.actor, ctx.trip.id, "activate", expected) end)

      try do
        assert waiting_on?(backend), "the transition must wait on the assignment row lock"
      after
        send(holder.pid, :commit)
      end

      assert {:ok, _load} = Task.await(holder, 10_000)

      if @versioned do
        assert {:error, :stale} = Task.await(requester, 10_000)
      else
        assert {:error, {:invalid, _}} = Task.await(requester, 10_000)
      end

      {:ok, %{assignments: [trip]}} = Board.load(ctx.actor, ctx.trip.load_id)
      [ended] = cancelled.assignments

      assert {trip.status, trip.ends_at, trip.version} ==
               {:CANCELLED, ended.ends_at, ctx.trip.version + 1}

      assert %{rows: [[1]]} =
               Repo.query!(
                 "SELECT count(*) FROM audit_events WHERE tenant_id = $1",
                 [Ecto.UUID.dump!(ctx.actor.tenant_id)]
               )
    end
  end

  test "competing cancellations with the same expected version commit only once", ctx do
    parent = self()
    cancel = fn -> Board.transition(ctx.actor, ctx.trip.id, "cancel", ctx.trip.version) end

    winner =
      session(fn ->
        Repo.transaction(fn ->
          assert {:ok, _} = cancel.()
          send(parent, {:pending, backend()})
          receive do: (:commit -> :ok)
        end)
      end)

    assert_receive {:pending, winner_backend}, 5_000
    contender = session(cancel)

    try do
      assert waiting_on?(winner_backend), "the contender must wait on the winning transaction"
    after
      send(winner.pid, :commit)
    end

    assert {:ok, :ok} = Task.await(winner, 10_000)
    assert {:error, :stale} = Task.await(contender, 10_000)

    trip = Ash.get!(Assignment, ctx.trip.id, authorize?: false, tenant: ctx.actor.tenant_id)
    assert {trip.status, trip.version} == {:CANCELLED, ctx.trip.version + 1}

    assert %{rows: [["assignment.cancelled"]]} =
             Repo.query!(
               "SELECT event_type FROM audit_events WHERE tenant_id = $1 AND subject_id = $2",
               [Ecto.UUID.dump!(ctx.actor.tenant_id), Ecto.UUID.dump!(ctx.trip.id)]
             )
  end

  test "rolling back an accepted transition discards both the trip update and audit", ctx do
    assert {:error, :negative_control} =
             Task.await(
               session(fn ->
                 Repo.transaction(fn ->
                   assert {:ok, _} =
                            Board.transition(ctx.actor, ctx.trip.id, "cancel", ctx.trip.version)

                   Repo.rollback(:negative_control)
                 end)
               end)
             )

    trip = Ash.get!(Assignment, ctx.trip.id, authorize?: false, tenant: ctx.actor.tenant_id)
    assert {trip.status, trip.version, trip.ends_at} ==
             {ctx.trip.status, ctx.trip.version, ctx.trip.ends_at}

    assert %{rows: []} =
             Repo.query!(
               "SELECT id FROM audit_events WHERE tenant_id = $1 AND subject_id = $2",
               [Ecto.UUID.dump!(ctx.actor.tenant_id), Ecto.UUID.dump!(ctx.trip.id)]
             )
  end

  test "an action holding an old snapshot cannot overwrite a newer version", ctx do
    {:ok, _} = Board.transition(ctx.actor, ctx.trip.id, "cancel", ctx.trip.version)

    assert {:error, _} =
             ctx.trip
             |> Ash.Changeset.for_update(:activate, %{})
             |> Ash.update(authorize?: false, tenant: ctx.actor.tenant_id)

    current = Ash.get!(Assignment, ctx.trip.id, authorize?: false, tenant: ctx.actor.tenant_id)
    assert current.status == :CANCELLED
    assert current.version == ctx.trip.version + 1
  end
end
