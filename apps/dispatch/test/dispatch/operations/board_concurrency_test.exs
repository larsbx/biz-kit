defmodule Dispatch.Operations.BoardConcurrencyTest do
  use ExUnit.Case, async: false

  alias Dispatch.Operations.Board
  alias Dispatch.Fleet.Assignment
  alias Dispatch.Repo
  alias Dispatch.Support.Fixtures
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

    on_exit(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      for table <- [
            "outbox_events",
            "audit_events",
            "consent_grants",
            "assignments",
            "loads",
            "role_assignments",
            "role_definitions",
            "participants"
          ] do
        Repo.query!("DELETE FROM #{table} WHERE tenant_id = $1", [Ecto.UUID.dump!(org.id)])
      end

      Repo.query!("DELETE FROM users WHERE id = $1", [Ecto.UUID.dump!(user.id)])
      Repo.query!("DELETE FROM organizations WHERE id = $1", [Ecto.UUID.dump!(org.id)])
      Sandbox.checkin(Repo)
    end)

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

  defp session(fun) do
    Task.async(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      try do
        fun.()
      after
        Sandbox.checkin(Repo)
      end
    end)
  end

  defp backend, do: Repo.query!("SELECT pg_backend_pid()").rows |> hd() |> hd()

  defp lock_trip(trip) do
    Repo.query!("SELECT id FROM assignments WHERE id = $1 FOR UPDATE", [Ecto.UUID.dump!(trip.id)])
  end

  defp waiting_on?(backend, attempts \\ 100)
  defp waiting_on?(_backend, 0), do: false

  defp waiting_on?(backend, attempts) do
    %{rows: [[waiting]]} =
      Repo.query!(
        """
        SELECT EXISTS (
          SELECT 1 FROM pg_stat_activity
          WHERE datname = current_database() AND $1 = ANY(pg_blocking_pids(pid))
        )
        """,
        [backend]
      )

    if waiting do
      true
    else
      Process.sleep(25)
      waiting_on?(backend, attempts - 1)
    end
  end
end
