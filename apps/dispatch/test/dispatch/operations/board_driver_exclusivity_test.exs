defmodule Dispatch.Operations.BoardDriverExclusivityTest do
  use ExUnit.Case, async: false

  import Dispatch.Support.ConcurrentSessions, only: [session: 1, backend: 0, waiting_on?: 1]

  alias Dispatch.Fleet.Assignment
  alias Dispatch.Operations.Board
  alias Dispatch.Repo
  alias Dispatch.Support.{ConcurrentSessions, Fixtures}
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :integration

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    org = Fixtures.carrier()
    %{user: dispatcher_user, participant: dispatcher} = Fixtures.person(org.id, org)
    actor = Fixtures.actor(org.id, org, dispatcher, "DISPATCHER")
    %{user: driver_user, participant: driver} = Fixtures.person(org.id, org)
    Fixtures.assignment(org.id, org, driver, "DRIVER")
    a = Fixtures.assignment_record(org.id, org, driver)
    b = Fixtures.assignment_record(org.id, org, driver)
    on_exit(:cleanup, fn -> ConcurrentSessions.cleanup(org, [dispatcher_user, driver_user]) end)

    %{
      org: org,
      actor: actor,
      driver: driver,
      driver_user: driver_user,
      dispatcher_user: dispatcher_user,
      a: a,
      b: b
    }
  end

  # Both transactions hold different trip locks. The unique index, rather
  # than a shared trip lock or a preflight count, must arbitrate the writes.
  for reverse <- [false, true], outcome <- [:commit, :rollback] do
    @reverse reverse
    @outcome outcome
    test "distinct-trip activation reverse=#{reverse} holder=#{outcome}", ctx do
      {first, second} = if @reverse, do: {ctx.b, ctx.a}, else: {ctx.a, ctx.b}
      {holder_result, contender_result} = race(ctx, first, second, "activate", 0, @outcome)

      if @outcome == :commit do
        assert {:ok, :committed} = holder_result
        assert {:error, {:invalid, _}} = contender_result
        assert_state(first, :ACTIVE, 1)
        assert_state(second, :PLANNED, 0)
        assert audits(first) == 1
        assert audits(second) == 0
      else
        assert {:error, :forced_rollback} = holder_result
        assert {:ok, _} = contender_result
        assert_state(first, :PLANNED, 0)
        assert_state(second, :ACTIVE, 1)
        assert audits(first) == 0
        assert audits(second) == 1
      end
    end
  end

  for terminal <- ["cancel", "complete"], outcome <- [:commit, :rollback] do
    @terminal terminal
    @outcome outcome
    test "#{terminal} releases the slot only on #{outcome}", ctx do
      assert {:ok, _} = Board.transition(ctx.actor, ctx.a.id, "activate", 0)
      {holder_result, contender_result} = race(ctx, ctx.a, ctx.b, @terminal, 1, @outcome)

      if @outcome == :commit do
        assert {:ok, :committed} = holder_result
        assert {:ok, _} = contender_result
        status = if @terminal == "cancel", do: :CANCELLED, else: :COMPLETED
        assert_state(ctx.a, status, 2)
        assert_state(ctx.b, :ACTIVE, 1)
        assert audits(ctx.a) == 2
        assert audits(ctx.b) == 1
      else
        assert {:error, :forced_rollback} = holder_result
        assert {:error, {:invalid, _}} = contender_result
        assert_state(ctx.a, :ACTIVE, 1)
        assert_state(ctx.b, :PLANNED, 0)
        assert audits(ctx.a) == 1
        assert audits(ctx.b) == 0
      end
    end
  end

  test "a stale distinct-trip activation consumes no slot or audit", ctx do
    assert {:error, :stale} = Board.transition(ctx.actor, ctx.b.id, "activate", -1)
    assert {:ok, _} = Board.transition(ctx.actor, ctx.a.id, "activate", 0)
    assert_state(ctx.b, :PLANNED, 0)
    assert audits(ctx.b) == 0
  end

  test "direct Ash writer also meets the index while Board holds another trip", ctx do
    parent = self()
    holder = held(ctx, ctx.a, "activate", 0, parent)
    assert_receive {:holding_exclusive, pid}, 5_000

    contender =
      session(fn ->
        send(parent, {:exclusive_contender, backend()})

        ctx.b
        |> Ash.Changeset.for_update(:activate, %{})
        |> Ash.update(authorize?: false, tenant: ctx.org.id)
      end)

    try do
      assert_contender_waits(pid)
    after
      send(holder.pid, :commit)
    end

    assert {:ok, :committed} = Task.await(holder, 10_000)
    assert {:error, _} = Task.await(contender, 10_000)
    assert_state(ctx.b, :PLANNED, 0)
    assert audits(ctx.b) == 0
  end

  @tag :global_driver_boundary
  test "one global user can currently activate in two tenants (scope witness)", ctx do
    other = Fixtures.carrier()
    %{participant: other_driver} = Fixtures.person(other.id, other, user: ctx.driver_user)
    Fixtures.assignment(other.id, other, other_driver, "DRIVER")
    other_actor = Fixtures.actor(other.id, other, other_driver, "DISPATCHER")
    other_trip = Fixtures.assignment_record(other.id, other, other_driver)
    # Delete the shared user only after both tenants have been cleaned.
    on_exit(:cleanup, fn ->
      ConcurrentSessions.cleanup(other, [])
      ConcurrentSessions.cleanup(ctx.org, [ctx.dispatcher_user, ctx.driver_user])
    end)

    parent = self()
    holder = held(ctx, ctx.a, "activate", 0, parent)
    assert_receive {:holding_exclusive, pid}, 5_000

    if System.get_env("DISPATCH_ASSERT_GLOBAL_DRIVER_EXCLUSIVITY") == "1" do
      contender =
        session(fn ->
          send(parent, {:exclusive_contender, backend()})
          Board.transition(other_actor, other_trip.id, "activate", 0)
        end)

      try do
        assert_contender_waits(pid)
      after
        send(holder.pid, :commit)
      end

      assert {:ok, :committed} = Task.await(holder, 10_000)
      assert {:error, {:invalid, _}} = Task.await(contender, 10_000)
      assert_state(other_trip, :PLANNED, 0)
      assert audits(other_trip) == 0
    else
      try do
        # Current tenant scope: completes while the first write is uncommitted.
        assert {:ok, _} =
                 Task.await(
                   session(fn ->
                     Board.transition(other_actor, other_trip.id, "activate", 0)
                   end),
                   5_000
                 )
      after
        send(holder.pid, :commit)
      end

      assert {:ok, :committed} = Task.await(holder, 10_000)
      assert_state(other_trip, :ACTIVE, 1)
    end

    assert_state(ctx.a, :ACTIVE, 1)
  end

  @tag :operator_profile_boundary
  test "a different participant's concurrent profile can currently relax a DRIVER trip", ctx do
    %{user: user, participant: courier} = Fixtures.person(ctx.org.id, ctx.org)
    {:ok, manifest} = Dispatch.Access.SeedManifest.fetch("DRIVER")

    definition =
      Dispatch.Accounts.RoleDefinition
      |> Ash.Changeset.for_create(:seed, %{
        tenant_id: ctx.org.id,
        key: "COURIER_CONTROL",
        label: "Courier control",
        capabilities_json: manifest.capabilities,
        constraints_json: manifest.constraints,
        profile_module: inspect(Dispatch.Support.Roles.Courier)
      })
      |> Ash.create!(authorize?: false, tenant: ctx.org.id)

    role = Fixtures.assignment(ctx.org.id, ctx.org, courier, "DRIVER", definition: definition)

    on_exit(:cleanup, fn ->
      ConcurrentSessions.cleanup(ctx.org, [ctx.dispatcher_user, ctx.driver_user, user])
    end)

    trip =
      Assignment
      |> Ash.Changeset.for_create(:plan, %{
        tenant_id: ctx.org.id,
        load_id: ctx.b.load_id,
        operator_participant_id: ctx.driver.id,
        starts_at: DateTime.utc_now(),
        operator_role_assignment_id: role.id
      })
      |> Ash.create!(authorize?: false, tenant: ctx.org.id)

    if System.get_env("DISPATCH_ASSERT_BOUND_DRIVER_PROFILE") == "1" do
      assert trip.operator_exclusive,
             "proposed acceptance: another participant's role must not relax exclusivity"

      assert {:ok, _} = Board.transition(ctx.actor, ctx.a.id, "activate", 0)
      assert {:error, {:invalid, _}} = Board.transition(ctx.actor, trip.id, "activate", 0)
      assert_state(trip, :PLANNED, 0)
      assert audits(trip) == 0
    else
      refute trip.operator_exclusive
      assert {:ok, _} = Board.transition(ctx.actor, ctx.a.id, "activate", 0)
      assert {:ok, _} = Board.transition(ctx.actor, trip.id, "activate", 0)
      assert_state(ctx.a, :ACTIVE, 1)
      assert_state(trip, :ACTIVE, 1)
    end
  end

  test "nonoverlapping recorded windows still conflict while both statuses are ACTIVE", ctx do
    # Index is status-based, not an exclusion constraint on [starts_at, ends_at).
    Repo.query!(
      "UPDATE assignments SET starts_at=now()-interval '2 days', ends_at=now()-interval '1 day' WHERE id=$1",
      [Ecto.UUID.dump!(ctx.a.id)]
    )

    assert {:ok, _} = Board.transition(ctx.actor, ctx.a.id, "activate", 0)
    assert {:error, {:invalid, _}} = Board.transition(ctx.actor, ctx.b.id, "activate", 0)
    assert_state(ctx.b, :PLANNED, 0)
  end

  test "raw UPDATE writer also waits on the partial index", ctx do
    holder = held(ctx, ctx.a, "activate", 0, self())
    assert_receive {:holding_exclusive, pid}, 5_000

    parent = self()

    contender =
      session(fn ->
        send(parent, {:exclusive_contender, backend()})

        Repo.query(
          "UPDATE assignments SET status='ACTIVE' WHERE id=$1",
          [Ecto.UUID.dump!(ctx.b.id)]
        )
      end)

    try do
      assert_contender_waits(pid)
    after
      send(holder.pid, :commit)
    end

    assert {:ok, :committed} = Task.await(holder, 10_000)

    assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
             Task.await(contender, 10_000)

    assert_state(ctx.b, :PLANNED, 0)
  end

  defp race(ctx, first, second, action, version, outcome) do
    holder = held(ctx, first, action, version, self())
    assert_receive {:holding_exclusive, pid}, 5_000
    parent = self()

    contender =
      session(fn ->
        send(parent, {:exclusive_contender, backend()})
        Board.transition(ctx.actor, second.id, "activate", 0)
      end)

    try do
      assert_contender_waits(pid)
      # Independent committed observation excludes the holder's audit/update.
      assert_state(second, :PLANNED, 0)
      assert audits(second) == 0
    after
      send(holder.pid, outcome)
    end

    {Task.await(holder, 10_000), Task.await(contender, 10_000)}
  end

  defp held(ctx, trip, action, version, parent) do
    session(fn ->
      Repo.transaction(fn ->
        assert {:ok, _} = Board.transition(ctx.actor, trip.id, action, version)
        send(parent, {:holding_exclusive, backend()})

        receive do
          :commit -> :committed
          :rollback -> Repo.rollback(:forced_rollback)
        after
          10_000 -> Repo.rollback(:test_barrier_timeout)
        end
      end)
    end)
  end

  defp assert_contender_waits(holder_backend) do
    assert_receive {:exclusive_contender, contender_backend}, 5_000
    assert waiting_on?(holder_backend), "distinct trip must wait on the index conflict"

    assert %{rows: [[true]]} =
             Repo.query!(
               "SELECT $1 = ANY(pg_blocking_pids($2))",
               [holder_backend, contender_backend]
             )
  end

  defp assert_state(trip, status, version) do
    current = Ash.get!(Assignment, trip.id, authorize?: false, tenant: trip.tenant_id)
    assert {current.status, current.version} == {status, version}
  end

  defp audits(trip) do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM audit_events WHERE tenant_id=$1 AND subject_id=$2",
        [Ecto.UUID.dump!(trip.tenant_id), Ecto.UUID.dump!(trip.id)]
      )

    n
  end
end
