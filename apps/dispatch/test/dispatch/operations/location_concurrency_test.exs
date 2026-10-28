defmodule Dispatch.Operations.LocationConcurrencyTest do
  use ExUnit.Case, async: false

  alias Dispatch.Operations.{ConsentGrant, Locations}
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
    actor = Fixtures.actor(org.id, org, driver, "DRIVER")
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

  test "concurrent begins with different keys return the same committed grant", ctx do
    parent = self()

    holder =
      session(fn ->
        Repo.transaction(fn ->
          lock_trip(ctx.trip)
          {:ok, grant} = Locations.begin_consent(ctx.actor, ctx.trip.id)
          send(parent, {:holding, backend(), grant})
          receive do: (:commit -> grant)
        end)
      end)

    assert_receive {:holding, backend, first}, 5_000
    requester = session(fn -> Locations.begin_consent(ctx.actor, ctx.trip.id) end)

    try do
      assert waiting_on?(backend), "begin must wait on the trip lock before reading grants"
    after
      send(holder.pid, :commit)
    end

    assert {:ok, ^first} = Task.await(holder, 10_000)
    assert {:ok, same} = Task.await(requester, 10_000)
    assert same.id == first.id
    assert map_size(Locations.covering(ctx.actor)) == 1
  end

  test "revocation waits for an in-flight grant and revokes it too", ctx do
    {:ok, first} = Locations.begin_consent(ctx.actor, ctx.trip.id)
    parent = self()

    holder =
      session(fn ->
        Repo.transaction(fn ->
          lock_trip(ctx.trip)

          twin =
            ConsentGrant
            |> Ash.Changeset.for_create(:begin_location_consent, %{
              tenant_id: ctx.actor.tenant_id,
              participant_id: ctx.actor.principal_id,
              role_assignment_id: ctx.actor.role_assignment.id,
              scope_json: %{"assignment_id" => ctx.trip.id}
            })
            |> Ash.create!(authorize?: false, tenant: ctx.actor.tenant_id)

          send(parent, {:holding, backend(), twin})
          receive do: (:commit -> twin)
        end)
      end)

    assert_receive {:holding, backend, _twin}, 5_000
    requester = session(fn -> Locations.revoke_consent(ctx.actor, first.id) end)

    try do
      assert waiting_on?(backend), "revoke must not pass an uncommitted grant"
    after
      send(holder.pid, :commit)
    end

    assert {:ok, _twin} = Task.await(holder, 10_000)
    assert {:ok, revoked} = Task.await(requester, 10_000)
    assert revoked.revoked_at
    assert Locations.covering(ctx.actor) == %{}
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
