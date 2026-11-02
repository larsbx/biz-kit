defmodule Dispatch.WriterAuthorityConcurrencyTest do
  @moduledoc """
  The #254 interleaving, for the Dispatch writers outside `Board` that wait on a
  lock after authorizing: role administration (the organization's advisory
  lock) and beginning location consent (the trip's row lock).

  Each runs in independently committed sessions. The write passes its entry
  check, queues on the lock, its author's authority changes in a committed
  transaction, and only then is the lock released.
  """
  use ExUnit.Case, async: false

  import Dispatch.Support.ConcurrentSessions,
    only: [session: 1, backend: 0, lock_trip: 1, waiting_on?: 1]

  alias Dispatch.Access.Actor
  alias Dispatch.Accounts.{Administration, RoleAssignment}
  alias Dispatch.Operations.{ConsentGrant, Locations}
  alias Dispatch.Repo
  alias Dispatch.Support.{ConcurrentSessions, Fixtures}
  alias Ecto.Adapters.SQL.Sandbox

  require Ash.Query

  @moduletag :integration

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    org = Fixtures.carrier()
    admin = Fixtures.role_definition(org.id, "ADMIN")

    people =
      for name <- ~w(First Second Third Driver),
          into: %{},
          do: {name, Fixtures.person(org.id, org, display_name: name)}

    grants =
      for name <- ~w(First Second Third),
          into: %{},
          do:
            {name,
             Fixtures.assignment(org.id, org, people[name].participant, "ADMIN",
               definition: admin
             )}

    on_exit(fn -> ConcurrentSessions.cleanup(org, Enum.map(people, fn {_, p} -> p.user end)) end)

    %{org: org, people: people, grants: grants}
  end

  describe "role administration, queued on the organization's lock" do
    test "an administrator revoked while queued cannot revoke another", ctx do
      [first, second, _third] = admins(ctx)

      assert {:error, :not_found} =
               queued_behind(
                 fn -> revoke(first, ctx.grants["Second"]) end,
                 fn -> revoke(second, ctx.grants["Third"]) end
               )

      assert active_admins(ctx) == Enum.sort([ctx.grants["First"].id, ctx.grants["Third"].id])
    end

    test "an administrator revoked while queued cannot grant", ctx do
      [first, second, _third] = admins(ctx)
      driver = ctx.people["Driver"].participant
      definition = Fixtures.role_definition(ctx.org.id, "DISPATCHER")

      grant = fn ->
        Administration.grant(
          second,
          %{"participant_id" => driver.id, "role_definition_id" => definition.id},
          DateTime.utc_now()
        )
      end

      assert {:error, :not_found} =
               queued_behind(fn -> revoke(first, ctx.grants["Second"]) end, grant)

      assert held_by(ctx, driver) == []
    end

    test "a stale snapshot of a revoked administrator cannot revoke", ctx do
      [first, second, _third] = admins(ctx)
      assert {:ok, _} = revoke(first, ctx.grants["Second"])

      assert {:error, :not_found} = revoke(second, ctx.grants["Third"])
      assert active_admins(ctx) == Enum.sort([ctx.grants["First"].id, ctx.grants["Third"].id])
    end

    test "control: an unrevoked administrator queued behind another still acts", ctx do
      [first, second, _third] = admins(ctx)
      driver = ctx.people["Driver"].participant
      definition = Fixtures.role_definition(ctx.org.id, "DISPATCHER")

      grant = fn d ->
        fn ->
          Administration.grant(
            d,
            %{"participant_id" => driver.id, "role_definition_id" => definition.id},
            DateTime.utc_now()
          )
        end
      end

      assert {:error, :already_granted} = queued_behind(grant.(first), grant.(second))
      assert length(held_by(ctx, driver)) == 1
    end
  end

  describe "beginning location consent, queued on the trip lock" do
    setup ctx do
      driver = ctx.people["Driver"].participant
      grant = Fixtures.assignment(ctx.org.id, ctx.org, driver, "DRIVER")
      {:ok, actor} = Actor.from_assignment(grant)

      %{
        driver_grant: grant,
        driver: actor,
        trip: Fixtures.assignment_record(ctx.org.id, ctx.org, driver)
      }
    end

    test "revoking the driver's assignment while it waits denies it", ctx do
      revoke = fn -> Fixtures.revoke(ctx.org.id, ctx.driver_grant) end

      assert {:error, :forbidden} =
               while_trip_locked(
                 ctx,
                 fn -> Locations.begin_consent(ctx.driver, ctx.trip.id) end,
                 revoke
               )

      assert consents(ctx) == []
    end

    test "control: an unchanged grant begins consent", ctx do
      assert {:ok, _grant} =
               while_trip_locked(
                 ctx,
                 fn -> Locations.begin_consent(ctx.driver, ctx.trip.id) end,
                 fn -> :ok end
               )

      assert length(consents(ctx)) == 1
    end
  end

  defp admins(ctx) do
    for name <- ~w(First Second Third) do
      {:ok, actor} = Actor.from_assignment(ctx.grants[name])
      actor
    end
  end

  defp revoke(actor, grant),
    do: Administration.revoke(actor, grant.id, grant.version, DateTime.utc_now())

  # Runs `first` in a transaction held open until `second` has queued on the
  # lock `first` took, then commits it and returns `second`'s result.
  defp queued_behind(first, second) do
    parent = self()

    holder =
      session(fn ->
        Repo.transaction(fn ->
          {:ok, _} = first.()
          send(parent, {:holding, backend()})
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive {:holding, holder_backend}, 5_000
    requester = session(second)

    try do
      assert waiting_on?(holder_backend), "the second write must queue on the first's lock"
    after
      send(holder.pid, :release)
    end

    assert {:ok, :ok} = Task.await(holder, 10_000)
    Task.await(requester, 10_000)
  end

  # Holds the trip lock, queues `write` behind it, commits `change`, releases.
  defp while_trip_locked(ctx, write, change) do
    parent = self()

    holder =
      session(fn ->
        Repo.transaction(fn ->
          lock_trip(ctx.trip)
          send(parent, {:holding, backend()})
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive {:holding, holder_backend}, 5_000
    requester = session(write)

    try do
      assert waiting_on?(holder_backend), "the write must queue on the trip lock"
      Task.await(session(change), 10_000)
      assert waiting_on?(holder_backend), "the change must commit while the write waits"
    after
      send(holder.pid, :release)
    end

    assert {:ok, :ok} = Task.await(holder, 10_000)
    Task.await(requester, 10_000)
  end

  defp active_admins(ctx) do
    RoleAssignment
    |> Ash.Query.for_read(:active, %{})
    |> Ash.Query.filter(role_definition_id == ^ctx.grants["First"].role_definition_id)
    |> Ash.read!(authorize?: false, tenant: ctx.org.id)
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end

  defp held_by(ctx, participant) do
    RoleAssignment
    |> Ash.Query.for_read(:active, %{})
    |> Ash.Query.filter(principal_id == ^participant.id)
    |> Ash.read!(authorize?: false, tenant: ctx.org.id)
  end

  defp consents(ctx) do
    ConsentGrant
    |> Ash.Query.filter(participant_id == ^ctx.driver.principal_id)
    |> Ash.read!(authorize?: false, tenant: ctx.org.id)
  end
end
