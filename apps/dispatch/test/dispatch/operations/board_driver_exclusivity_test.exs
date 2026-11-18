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

        assert {:error, {:invalid, "the driver is unavailable for this assignment"}} =
                 contender_result

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

        assert {:error, {:invalid, "the driver is unavailable for this assignment"}} =
                 contender_result

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

  for first_mode <- [:exclusive, :concurrent],
      second_mode <- [:exclusive, :concurrent],
      outcome <- [:commit, :rollback] do
    @first_mode first_mode
    @second_mode second_mode
    @outcome outcome
    test "global User across tenants #{first_mode}/#{second_mode} holder=#{outcome}", ctx do
      other = Fixtures.carrier()
      %{participant: other_driver} = Fixtures.person(other.id, other, user: ctx.driver_user)
      Fixtures.assignment(other.id, other, other_driver, "DRIVER")
      other_actor = Fixtures.actor(other.id, other, other_driver, "DISPATCHER")
      other_base = Fixtures.assignment_record(other.id, other, other_driver)
      first = trip_with_mode(ctx.org, ctx.driver, ctx.a, @first_mode)
      second = trip_with_mode(other, other_driver, other_base, @second_mode)

      on_exit(:cleanup, fn ->
        ConcurrentSessions.cleanup(other, [])
        ConcurrentSessions.cleanup(ctx.org, [ctx.dispatcher_user, ctx.driver_user])
      end)

      assert first.operator_user_id == second.operator_user_id
      refute first.operator_participant_id == second.operator_participant_id
      holder = held(ctx, first, "activate", 0, self())
      assert_receive {:holding_exclusive, pid}, 5_000
      parent = self()

      contender =
        session(fn ->
          send(parent, {:exclusive_contender, backend()})
          Board.transition(other_actor, second.id, "activate", 0)
        end)

      both_concurrent = @first_mode == :concurrent and @second_mode == :concurrent

      contender_result =
        if both_concurrent do
          try do
            # C/C must finish before the other transaction is released.
            Task.await(contender, 5_000)
          after
            send(holder.pid, @outcome)
          end
        else
          try do
            assert_contender_waits(pid)
            assert_state(second, :PLANNED, 0)
            assert audits(second) == 0
          after
            send(holder.pid, @outcome)
          end

          Task.await(contender, 10_000)
        end

      holder_result = Task.await(holder, 10_000)

      if @outcome == :commit do
        assert {:ok, :committed} = holder_result
        assert_state(first, :ACTIVE, 1)
        assert audits(first) == 1
      else
        assert {:error, :forced_rollback} = holder_result
        assert_state(first, :PLANNED, 0)
        assert audits(first) == 0
      end

      if both_concurrent or @outcome == :rollback do
        assert {:ok, _} = contender_result
        assert_state(second, :ACTIVE, 1)
        assert audits(second) == 1
      else
        assert {:error, {:invalid, "the driver is unavailable for this assignment"}} =
                 contender_result

        assert_state(second, :PLANNED, 0)
        assert audits(second) == 0
      end
    end
  end

  test "another participant's concurrent grant is rejected instead of falling back", ctx do
    %{user: user, participant: courier} = Fixtures.person(ctx.org.id, ctx.org)
    role = courier_role(ctx.org, courier)

    on_exit(:cleanup, fn ->
      ConcurrentSessions.cleanup(ctx.org, [ctx.dispatcher_user, ctx.driver_user, user])
    end)

    assert {:error, _} = plan(ctx.org, ctx.driver, ctx.b, role)
    assert_state(ctx.a, :PLANNED, 0)
    assert_state(ctx.b, :PLANNED, 0)
    assert audits(ctx.a) == 0
    assert audits(ctx.b) == 0
  end

  for reverse <- [false, true], outcome <- [:commit, :rollback] do
    @reverse reverse
    @outcome outcome
    test "bound mixed modes reverse=#{reverse} holder=#{outcome}", ctx do
      concurrent = trip_with_mode(ctx.org, ctx.driver, ctx.b, :concurrent)
      assert concurrent.operator_user_id == ctx.driver_user.id
      refute concurrent.operator_exclusive
      assert concurrent.operator_role_assignment_id
      assert concurrent.operator_role_definition_id
      {first, second} = if @reverse, do: {concurrent, ctx.a}, else: {ctx.a, concurrent}
      {holder_result, contender_result} = race(ctx, first, second, "activate", 0, @outcome)

      if @outcome == :commit do
        assert {:ok, :committed} = holder_result

        assert {:error, {:invalid, "the driver is unavailable for this assignment"}} =
                 contender_result

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

  test "same-tenant concurrent trips wait at the audit append, then both commit", ctx do
    role = courier_role(ctx.org, ctx.driver)
    assert {:ok, first} = plan(ctx.org, ctx.driver, ctx.a, role)
    assert {:ok, second} = plan(ctx.org, ctx.driver, ctx.b, role)
    assert_shared_audit_serializes(ctx, first, second)
  end

  test "same-tenant exclusive trips for different Users wait only at the audit append", ctx do
    %{user: user, participant: driver} = Fixtures.person(ctx.org.id, ctx.org)
    Fixtures.assignment(ctx.org.id, ctx.org, driver, "DRIVER")
    second = Fixtures.assignment_record(ctx.org.id, ctx.org, driver)

    on_exit(:cleanup, fn ->
      ConcurrentSessions.cleanup(ctx.org, [ctx.dispatcher_user, ctx.driver_user, user])
    end)

    refute second.operator_user_id == ctx.a.operator_user_id
    assert_shared_audit_serializes(ctx, ctx.a, second)
  end

  test "cross-tenant exclusive trips for different Users commit independently", ctx do
    other = Fixtures.carrier()
    %{user: user, participant: driver} = Fixtures.person(other.id, other)
    Fixtures.assignment(other.id, other, driver, "DRIVER")
    actor = Fixtures.actor(other.id, other, driver, "DISPATCHER")
    second = Fixtures.assignment_record(other.id, other, driver)
    on_exit(fn -> ConcurrentSessions.cleanup(other, [user]) end)

    refute second.operator_user_id == ctx.a.operator_user_id
    holder = held(ctx, ctx.a, "activate", 0, self())

    try do
      assert_receive {:holding_exclusive, _}, 5_000
      contender = session(fn -> Board.transition(actor, second.id, "activate", 0) end)
      assert {:ok, _} = Task.await(contender, 5_000)

      assert_state(ctx.a, :PLANNED, 0)
      assert_state(second, :ACTIVE, 1)
      assert audits(second) == 1
    after
      send(holder.pid, :commit)
    end

    assert {:ok, :committed} = Task.await(holder, 10_000)
    assert_state(ctx.a, :ACTIVE, 1)
    assert audits(ctx.a) == 1
  end

  test "reenrolment of one User does not release an old active assignment", ctx do
    assert {:ok, _} = Board.transition(ctx.actor, ctx.a.id, "activate", 0)

    Repo.query!("UPDATE participants SET status='CLOSED' WHERE id=$1", [
      Ecto.UUID.dump!(ctx.driver.id)
    ])

    %{participant: replacement} = Fixtures.person(ctx.org.id, ctx.org, user: ctx.driver_user)
    Fixtures.assignment(ctx.org.id, ctx.org, replacement, "DRIVER")
    trip = Fixtures.assignment_record(ctx.org.id, ctx.org, replacement)
    assert trip.operator_user_id == ctx.a.operator_user_id
    refute trip.operator_participant_id == ctx.a.operator_participant_id

    assert {:error, {:invalid, "the driver is unavailable for this assignment"}} =
             Board.transition(ctx.actor, trip.id, "activate", 0)

    assert_state(trip, :PLANNED, 0)
    assert audits(trip) == 0
    assert {:ok, _} = Board.transition(ctx.actor, ctx.a.id, "complete", 1)
    assert {:ok, _} = Board.transition(ctx.actor, trip.id, "activate", 0)
    assert_state(ctx.a, :COMPLETED, 2)
    assert_state(trip, :ACTIVE, 1)
    assert audits(ctx.a) == 2
    assert audits(trip) == 1
  end

  test "an exclusive contender waits until both concurrent releases commit", ctx do
    other = Fixtures.carrier()
    %{participant: other_driver} = Fixtures.person(other.id, other, user: ctx.driver_user)
    other_actor = Fixtures.actor(other.id, other, other_driver, "DISPATCHER")
    other_base = Fixtures.assignment_record(other.id, other, other_driver)

    on_exit(:cleanup, fn ->
      ConcurrentSessions.cleanup(other, [])
      ConcurrentSessions.cleanup(ctx.org, [ctx.dispatcher_user, ctx.driver_user])
    end)

    # Separate audit chains let both releases reach their barriers independently.
    first = trip_with_mode(ctx.org, ctx.driver, ctx.a, :concurrent)
    second = trip_with_mode(other, other_driver, other_base, :concurrent)
    assert first.operator_user_id == second.operator_user_id
    assert {:ok, _} = Board.transition(ctx.actor, first.id, "activate", 0)
    assert {:ok, _} = Board.transition(other_actor, second.id, "activate", 0)
    holder_a = held(ctx, first, "cancel", 1, self())
    assert_receive {:holding_exclusive, pid_a}, 5_000
    holder_b = held(%{actor: other_actor}, second, "complete", 1, self())
    parent = self()

    try do
      assert_receive {:holding_exclusive, pid_b}, 5_000

      contender =
        session(fn ->
          send(parent, {:exclusive_contender, backend()})
          Board.transition(ctx.actor, ctx.a.id, "activate", 0)
        end)

      assert_receive {:exclusive_contender, contender_pid}, 5_000
      blocker = await_blocker(contender_pid, [pid_a, pid_b], "transactionid")

      {released, remaining, remaining_pid} =
        if blocker == pid_a,
          do: {holder_a, holder_b, pid_b},
          else: {holder_b, holder_a, pid_a}

      send(released.pid, :commit)
      assert {:ok, :committed} = Task.await(released, 10_000)
      assert await_blocker(contender_pid, [remaining_pid], "transactionid") == remaining_pid
      assert_state(ctx.a, :PLANNED, 0)
      assert audits(ctx.a) == 0
      send(remaining.pid, :commit)
      assert {:ok, :committed} = Task.await(remaining, 10_000)
      assert {:ok, _} = Task.await(contender, 10_000)
    after
      send(holder_a.pid, :commit)
      send(holder_b.pid, :commit)
    end

    assert_state(first, :CANCELLED, 2)
    assert_state(second, :COMPLETED, 2)
    assert_state(ctx.a, :ACTIVE, 1)
    assert audits(first) == 2
    assert audits(second) == 2
    assert audits(ctx.a) == 1
  end

  test "nonoverlapping recorded windows still conflict while both statuses are ACTIVE", ctx do
    # Occupancy is status-based; recorded intervals do not release an ACTIVE trip.
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

  test "raw UPDATE cannot bypass mixed-mode exclusion", ctx do
    concurrent = trip_with_mode(ctx.org, ctx.driver, ctx.b, :concurrent)
    holder = held(ctx, concurrent, "activate", 0, self())
    assert_receive {:holding_exclusive, pid}, 5_000
    parent = self()

    contender =
      session(fn ->
        send(parent, {:exclusive_contender, backend()})

        Repo.query("UPDATE assignments SET status='ACTIVE' WHERE id=$1", [
          Ecto.UUID.dump!(ctx.a.id)
        ])
      end)

    try do
      assert_contender_waits(pid)
    after
      send(holder.pid, :commit)
    end

    assert {:ok, :committed} = Task.await(holder, 10_000)

    assert {:error, %Postgrex.Error{postgres: %{code: :exclusion_violation}}} =
             Task.await(contender, 10_000)

    assert_state(ctx.a, :PLANNED, 0)
    assert audits(ctx.a) == 0
  end

  defp trip_with_mode(_org, _driver, base, :exclusive), do: base

  defp trip_with_mode(org, driver, base, :concurrent) do
    role = courier_role(org, driver)
    assert {:ok, trip} = plan(org, driver, base, role)
    trip
  end

  defp courier_role(org, driver) do
    {:ok, manifest} = Dispatch.Access.SeedManifest.fetch("DRIVER")

    definition =
      Dispatch.Accounts.RoleDefinition
      |> Ash.Changeset.for_create(:seed, %{
        tenant_id: org.id,
        key: "COURIER_E3_#{System.unique_integer([:positive])}",
        label: "Concurrent driver",
        capabilities_json: manifest.capabilities,
        constraints_json: manifest.constraints,
        profile_module: inspect(Dispatch.Support.Roles.Courier)
      })
      |> Ash.create!(authorize?: false, tenant: org.id)

    Fixtures.assignment(org.id, org, driver, "DRIVER", definition: definition)
  end

  defp plan(org, driver, base, role) do
    Assignment
    |> Ash.Changeset.for_create(:plan, %{
      tenant_id: org.id,
      load_id: base.load_id,
      operator_participant_id: driver.id,
      starts_at: DateTime.utc_now(),
      operator_role_assignment_id: role.id
    })
    |> Ash.create(authorize?: false, tenant: org.id)
  end

  defp assert_shared_audit_serializes(ctx, first, second) do
    holder = held(ctx, first, "activate", 0, self())
    parent = self()

    contender =
      try do
        assert_receive {:holding_exclusive, holder_pid}, 5_000

        contender =
          session(fn ->
            send(parent, {:audit_contender, backend()})
            Board.transition(ctx.actor, second.id, "activate", 0)
          end)

        assert_receive {:audit_contender, contender_pid}, 5_000
        assert await_blocker(contender_pid, [holder_pid], "advisory") == holder_pid
        assert_state(second, :PLANNED, 0)
        assert audits(second) == 0
        contender
      after
        send(holder.pid, :commit)
      end

    assert {:ok, :committed} = Task.await(holder, 10_000)
    assert {:ok, _} = Task.await(contender, 10_000)
    assert_state(first, :ACTIVE, 1)
    assert_state(second, :ACTIVE, 1)
    assert audits(first) == 1
    assert audits(second) == 1

    assert %{rows: [[true]]} =
             Repo.query!(
               """
               SELECT following.previous_event_hash = preceding.event_hash
               FROM audit_events preceding JOIN audit_events following USING (tenant_id)
               WHERE tenant_id = $1 AND preceding.subject_id = $2 AND following.subject_id = $3
               """,
               Enum.map([first.tenant_id, first.id, second.id], &Ecto.UUID.dump!/1)
             )
  end

  defp await_blocker(contender_pid, expected, wait_event, attempts \\ 100)

  defp await_blocker(_contender_pid, _expected, wait_event, 0),
    do: flunk("contender did not wait on the expected #{wait_event} lock")

  defp await_blocker(contender_pid, expected, wait_event, attempts) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT pg_blocking_pids(pid) FROM pg_stat_activity
        WHERE pid = $1 AND wait_event_type = 'Lock' AND wait_event = $2
        """,
        [contender_pid, wait_event]
      )

    case Enum.find(expected, fn pid -> Enum.any?(rows, fn [blockers] -> pid in blockers end) end) do
      nil ->
        Process.sleep(25)
        await_blocker(contender_pid, expected, wait_event, attempts - 1)

      pid ->
        pid
    end
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
