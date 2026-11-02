defmodule Dispatch.Operations.BoardAuthorityConcurrencyTest do
  @moduledoc """
  Issue #254: a board write must be authorized by the grant as committed when
  it mutates, not by the `Actor` snapshot it was called with.

  Each interleaving runs in independently committed sessions: a holder takes
  the trip's row lock, the transition passes its entry check and queues on that
  lock, a third session commits a change to the dispatcher's authority, and only
  then is the lock released.
  """
  use ExUnit.Case, async: false

  import Dispatch.Support.ConcurrentSessions,
    only: [session: 1, backend: 0, lock_trip: 1, waiting_on?: 1]

  alias Dispatch.Access.Actor
  alias Dispatch.Accounts.User
  alias Dispatch.Fleet.Assignment
  alias Dispatch.Operations.Board
  alias Dispatch.Repo
  alias Dispatch.Support.{ConcurrentSessions, Fixtures}
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :integration

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    org = Fixtures.carrier()
    %{user: user, participant: dispatcher} = Fixtures.person(org.id, org)
    grant = Fixtures.assignment(org.id, org, dispatcher, "DISPATCHER")
    {:ok, actor} = Actor.from_assignment(grant)
    trip = Fixtures.assignment_record(org.id, org, dispatcher)

    on_exit(fn -> ConcurrentSessions.cleanup(org, [user]) end)

    %{org: org, user: user, dispatcher: dispatcher, grant: grant, actor: actor, trip: trip}
  end

  describe "a change committed while the transition waits on the trip lock" do
    test "revoking the selected assignment denies it", ctx do
      assert {:error, :forbidden} =
               interleaved(ctx, fn -> Fixtures.revoke(ctx.org.id, ctx.grant) end)

      assert_unchanged(ctx)
    end

    test "removing the capability from the role definition denies it", ctx do
      # No Ash action may change a used definition's authority (Section 23.3);
      # a data migration is the one path that can, so the test takes it.
      revoke_capability = fn ->
        Repo.query!(
          """
          UPDATE role_definitions
          SET capabilities_json = array_remove(capabilities_json, 'assignment.update.status')
          WHERE id = $1
          """,
          [Ecto.UUID.dump!(ctx.grant.role_definition_id)]
        )
      end

      assert {:error, :forbidden} = interleaved(ctx, revoke_capability)
      assert_unchanged(ctx)
    end

    test "the assignment's validity interval ending denies it", ctx do
      ends_at = DateTime.add(DateTime.utc_now(), 1_500, :millisecond)

      ctx = regrant(ctx, ends_at: ends_at)

      outlive = fn ->
        Process.sleep(max(DateTime.diff(ends_at, DateTime.utc_now(), :millisecond), 0) + 100)
      end

      assert {:error, :forbidden} = interleaved(ctx, outlive)
      assert_unchanged(ctx)
    end

    test "suspending the participant denies it", ctx do
      suspend = fn ->
        ctx.dispatcher
        |> Ash.Changeset.for_update(:set_status, %{status: :SUSPENDED})
        |> Ash.update!(authorize?: false, tenant: ctx.org.id)
      end

      assert {:error, :forbidden} = interleaved(ctx, suspend)
      assert_unchanged(ctx)
    end

    test "suspending the user denies it", ctx do
      suspend = fn ->
        User
        |> Ash.get!(ctx.user.id, authorize?: false)
        |> Ash.Changeset.for_update(:set_status, %{status: :SUSPENDED})
        |> Ash.update!(authorize?: false)
      end

      assert {:error, :forbidden} = interleaved(ctx, suspend)
      assert_unchanged(ctx)
    end

    test "a second assignment the user still holds does not stand in for the revoked one", ctx do
      _other = second_grant(ctx)

      assert {:error, :forbidden} =
               interleaved(ctx, fn -> Fixtures.revoke(ctx.org.id, ctx.grant) end)

      assert_unchanged(ctx)
    end

    test "revoking an assignment that was not selected leaves the selected one in force", ctx do
      other = second_grant(ctx)

      assert {:ok, _load} = interleaved(ctx, fn -> Fixtures.revoke(ctx.org.id, other) end)
      assert_moved(ctx)
    end

    test "an unchanged grant still moves the trip (control)", ctx do
      assert {:ok, _load} = interleaved(ctx, fn -> :unchanged end)
      assert_moved(ctx)
    end
  end

  describe "a stale actor snapshot" do
    test "a grant revoked before the call is refused", ctx do
      Fixtures.revoke(ctx.org.id, ctx.grant)

      assert {:error, :forbidden} =
               Board.transition(ctx.actor, ctx.trip.id, "activate", ctx.trip.version)

      assert_unchanged(ctx)
    end

    test "a caller-chosen instant inside an ended interval is not the authority", ctx do
      now = DateTime.utc_now()

      ctx =
        regrant(ctx, [ends_at: DateTime.add(now, -1, :second)], DateTime.add(now, -10, :second))

      assert Actor.can?(ctx.actor, "assignment.update.status"),
             "the snapshot alone would allow it"

      assert {:error, :forbidden} =
               Board.transition(ctx.actor, ctx.trip.id, "activate", ctx.trip.version)

      assert_unchanged(ctx)
    end

    test "every board write refuses it and records nothing", ctx do
      load = Board.load(ctx.actor, ctx.trip.load_id) |> elem(1)
      Fixtures.revoke(ctx.org.id, ctx.grant)

      writes = [
        fn -> Board.create_load(ctx.actor, %{"external_reference" => "STALE"}) end,
        fn ->
          Board.update_load(ctx.actor, load.id, %{
            "commodity_text" => "stale",
            "expected_version" => load.version
          })
        end,
        fn ->
          Board.add_stop(ctx.actor, load.id, %{"kind" => "PICKUP", "address_text" => "x"})
        end,
        fn ->
          Board.plan(ctx.actor, load.id, %{"operator_participant_id" => ctx.dispatcher.id})
        end
      ]

      for write <- writes, do: assert({:error, :forbidden} = write.())

      assert audit_count(ctx) == 0
      assert %{rows: [[1]]} = count("loads", ctx)
      assert %{rows: [[0]]} = count("stops", ctx)
      assert %{rows: [[1]]} = count("assignments", ctx)
    end
  end

  # Replaces the setup grant with one shaped by `opts`; only one active grant of
  # a definition per principal and scope may exist.
  defp regrant(ctx, opts, at \\ DateTime.utc_now()) do
    Fixtures.revoke(ctx.org.id, ctx.grant)
    grant = Fixtures.assignment(ctx.org.id, ctx.org, ctx.dispatcher, "DISPATCHER", opts)
    {:ok, actor} = Actor.from_assignment(grant, at: at)
    %{ctx | grant: grant, actor: actor}
  end

  # Another active assignment for the same participant that also carries
  # `assignment.update.status`: a second definition with the dispatcher manifest.
  defp second_grant(ctx) do
    {:ok, manifest} = Dispatch.Access.SeedManifest.fetch("DISPATCHER")

    definition =
      Dispatch.Accounts.RoleDefinition
      |> Ash.Changeset.for_create(:seed, %{
        tenant_id: ctx.org.id,
        key: "DISPATCHER_NIGHT",
        label: "Night dispatcher",
        capabilities_json: manifest.capabilities,
        constraints_json: manifest.constraints,
        profile_module: inspect(manifest.profile_module)
      })
      |> Ash.create!(authorize?: false, tenant: ctx.org.id)

    Fixtures.assignment(ctx.org.id, ctx.org, ctx.dispatcher, "DISPATCHER", definition: definition)
  end

  # Holds the trip lock, queues the transition behind it, commits `change` in a
  # third session while the transition waits, then releases the lock.
  defp interleaved(ctx, change) do
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

    requester =
      session(fn -> Board.transition(ctx.actor, ctx.trip.id, "activate", ctx.trip.version) end)

    try do
      assert waiting_on?(holder_backend), "the transition must queue on the trip lock"
      Task.await(session(change), 10_000)
      assert waiting_on?(holder_backend), "the change must commit while the transition waits"
    after
      send(holder.pid, :release)
    end

    assert {:ok, :ok} = Task.await(holder, 10_000)
    Task.await(requester, 10_000)
  end

  defp assert_unchanged(ctx) do
    trip = reload(ctx)
    assert {trip.status, trip.version} == {ctx.trip.status, ctx.trip.version}
    assert audit_count(ctx) == 0
  end

  defp assert_moved(ctx) do
    trip = reload(ctx)
    assert {trip.status, trip.version} == {:ACTIVE, ctx.trip.version + 1}

    assert %{rows: [[1, role_assignment_id]]} =
             Repo.query!(
               """
               SELECT count(*), min(role_assignment_id::text) FROM audit_events
               WHERE tenant_id = $1 AND subject_id = $2
               """,
               [Ecto.UUID.dump!(ctx.org.id), Ecto.UUID.dump!(ctx.trip.id)]
             )

    assert role_assignment_id == ctx.grant.id, "the audit names the selected assignment"
  end

  defp reload(ctx), do: Ash.get!(Assignment, ctx.trip.id, authorize?: false, tenant: ctx.org.id)

  defp audit_count(ctx) do
    %{rows: [[n]]} = count("audit_events", ctx)
    n
  end

  defp count(table, ctx),
    do:
      Repo.query!("SELECT count(*) FROM #{table} WHERE tenant_id = $1", [
        Ecto.UUID.dump!(ctx.org.id)
      ])
end
