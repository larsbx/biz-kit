defmodule Dispatch.Fleet.AssignmentPolicyTest do
  use ExUnit.Case, async: false

  import Dispatch.Support.ConcurrentSessions, only: [session: 1, backend: 0, waiting_on?: 1]

  alias Dispatch.Accounts.RoleDefinition
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
    driver_role = Fixtures.assignment(org.id, org, driver, "DRIVER")
    base = Fixtures.assignment_record(org.id, org, driver)
    definition = courier_definition(org)
    role = Fixtures.assignment(org.id, org, driver, "DRIVER", definition: definition)

    ctx = %{
      org: org,
      dispatcher: dispatcher,
      dispatcher_user: dispatcher_user,
      actor: actor,
      driver: driver,
      driver_user: driver_user,
      driver_role: driver_role,
      base: base,
      definition: definition,
      role: role
    }

    assert {:ok, concurrent} = plan(ctx, role.id)
    on_exit(:cleanup, fn -> ConcurrentSessions.cleanup(org, [dispatcher_user, driver_user]) end)
    Map.put(ctx, :concurrent, concurrent)
  end

  test "planning derives the User and freezes the selected grant and definition", ctx do
    assert ctx.base.operator_user_id == ctx.driver_user.id
    assert ctx.base.operator_exclusive
    assert is_nil(ctx.base.operator_role_assignment_id)
    assert is_nil(ctx.base.operator_role_definition_id)
    assert ctx.concurrent.operator_user_id == ctx.driver_user.id
    refute ctx.concurrent.operator_exclusive
    assert ctx.concurrent.operator_role_assignment_id == ctx.role.id
    assert ctx.concurrent.operator_role_definition_id == ctx.definition.id
    assert {:ok, _} = Board.transition(ctx.actor, ctx.concurrent.id, "activate", 0)
    assert_unchanged_policy(ctx.concurrent)
  end

  test "Board selects a valid concurrent source before an unrelated exclusive scope", ctx do
    Fixtures.revoke(ctx.org.id, ctx.driver_role)
    unrelated_load = Fixtures.load(ctx.org.id, ctx.org)

    Fixtures.assignment(ctx.org.id, ctx.org, ctx.driver, "DRIVER",
      definition: ctx.driver_role.role_definition,
      scope_type: :LOAD,
      scope_id: unrelated_load.id
    )

    assert {:ok, load} =
             Board.plan(ctx.actor, ctx.base.load_id, %{
               "operator_participant_id" => ctx.driver.id
             })

    planned = Enum.find(load.assignments, &(&1.id not in [ctx.base.id, ctx.concurrent.id]))
    assert planned
    refute planned.operator_exclusive
    assert planned.operator_role_assignment_id == ctx.role.id
    assert planned.operator_role_definition_id == ctx.definition.id
    assert planned.operator_user_id == ctx.driver_user.id
    assert audit_count(planned) == 1
    assert {:ok, _} = Board.transition(ctx.actor, planned.id, "activate", 0)
    assert audit_count(planned) == 2
  end

  test "unknown explicit role fails planning without an exclusive fallback", ctx do
    before_count = assignment_count(ctx.org)
    assert {:error, _} = plan(ctx, Ash.UUID.generate())
    assert assignment_count(ctx.org) == before_count
  end

  test "another participant's role fails planning without writing an assignment", ctx do
    role =
      Fixtures.assignment(ctx.org.id, ctx.org, ctx.dispatcher, "DRIVER",
        definition: ctx.definition
      )

    before_count = assignment_count(ctx.org)
    assert {:error, _} = plan(ctx, role.id)
    assert assignment_count(ctx.org) == before_count
  end

  test "a role from another tenant cannot authorize this tenant's assignment", ctx do
    other = Fixtures.carrier()
    %{participant: participant} = Fixtures.person(other.id, other, user: ctx.driver_user)
    definition = courier_definition(other)
    role = Fixtures.assignment(other.id, other, participant, "DRIVER", definition: definition)

    on_exit(:cleanup, fn ->
      ConcurrentSessions.cleanup(other, [])
      ConcurrentSessions.cleanup(ctx.org, [ctx.dispatcher_user, ctx.driver_user])
    end)

    assert {:error, _} = plan(ctx, role.id)
    assert assignment_count(ctx.org) == 2
  end

  test "a grant for a different carrier cannot authorize the load", ctx do
    other = Fixtures.carrier()

    role =
      Fixtures.assignment(ctx.org.id, other, ctx.driver, "DRIVER", definition: ctx.definition)

    on_exit(:cleanup, fn ->
      ConcurrentSessions.cleanup(ctx.org, [ctx.dispatcher_user, ctx.driver_user])
      ConcurrentSessions.cleanup(other, [])
    end)

    assert {:error, _} = plan(ctx, role.id)
    assert assignment_count(ctx.org) == 2
  end

  for scope <- [:LOAD, :ASSIGNMENT, :STOP] do
    @scope scope
    test "an unrelated #{@scope} grant cannot authorize planning", ctx do
      role =
        Fixtures.assignment(ctx.org.id, ctx.org, ctx.driver, "DRIVER",
          definition: ctx.definition,
          scope_type: @scope,
          scope_id: Ash.UUID.generate()
        )

      assert {:error, _} = plan(ctx, role.id)
      assert assignment_count(ctx.org) == 2
    end
  end

  for change <- [
        :revoked,
        :expired,
        :future,
        :definition_superseded,
        :capability_removed,
        :mode_changed,
        :principal_changed,
        :scope_changed
      ] do
    @source_change change
    test "#{change} source cannot activate the previously planned decision", ctx do
      mutate_source(ctx, @source_change)

      if @source_change == :mode_changed do
        # A new plan takes today's mode; the old plan must not change mode.
        assert {:ok, fresh} = plan(ctx, ctx.role.id)
        assert fresh.operator_exclusive
      else
        assert {:error, _} = plan(ctx, ctx.role.id)
      end

      assert {:error, {:invalid, "the driver no longer holds a driving role"}} =
               Board.transition(ctx.actor, ctx.concurrent.id, "activate", 0)

      assert_planned_without_audit(ctx.concurrent)
      assert_unchanged_policy(ctx.concurrent)

      assert {:error, _} =
               ctx.concurrent
               |> Ash.Changeset.for_update(:activate, %{})
               |> Ash.update(authorize?: false, tenant: ctx.org.id)

      assert_planned_without_audit(ctx.concurrent)
    end
  end

  test "changing to a different current concurrent definition invalidates stored provenance",
       ctx do
    replacement = courier_definition(ctx.org)

    Repo.query!(
      "UPDATE role_assignments SET role_definition_id=$2 WHERE id=$1",
      [uuid(ctx.role.id), uuid(replacement.id)]
    )

    assert {:error, {:invalid, "the driver no longer holds a driving role"}} =
             Board.transition(ctx.actor, ctx.concurrent.id, "activate", 0)

    assert_planned_without_audit(ctx.concurrent)
    assert_unchanged_policy(ctx.concurrent)
  end

  test "relabeling a definition changes no assignment authority", ctx do
    ctx.definition
    |> Ash.Changeset.for_update(:relabel, %{label: "A new display name"})
    |> Ash.update!(authorize?: false, tenant: ctx.org.id)

    assert {:ok, _} = Board.transition(ctx.actor, ctx.concurrent.id, "activate", 0)
    assert_unchanged_policy(ctx.concurrent)
  end

  test "an omitted source cannot activate using only a concurrent grant", ctx do
    Repo.query!("UPDATE role_assignments SET status='REVOKED' WHERE id=$1", [
      uuid(ctx.driver_role.id)
    ])

    assert {:error, {:invalid, "the driver no longer holds a driving role"}} =
             Board.transition(ctx.actor, ctx.base.id, "activate", 0)

    assert_planned_without_audit(ctx.base)
    assert {:ok, _} = Board.transition(ctx.actor, ctx.concurrent.id, "activate", 0)
  end

  for outcome <- [:commit, :rollback] do
    @outcome outcome
    test "activation rereads a concurrent source revocation after #{@outcome}", ctx do
      parent = self()

      holder =
        session(fn ->
          Repo.transaction(fn ->
            Repo.query!("UPDATE role_assignments SET status='REVOKED' WHERE id=$1", [
              uuid(ctx.role.id)
            ])

            send(parent, {:source_locked, backend()})

            receive do
              :commit -> :committed
              :rollback -> Repo.rollback(:forced_rollback)
            after
              10_000 -> Repo.rollback(:test_barrier_timeout)
            end
          end)
        end)

      assert_receive {:source_locked, holder_pid}, 5_000

      contender =
        session(fn ->
          send(parent, {:source_contender, backend()})
          Board.transition(ctx.actor, ctx.concurrent.id, "activate", 0)
        end)

      assert_receive {:source_contender, contender_pid}, 5_000

      try do
        assert waiting_on?(holder_pid)

        assert %{rows: [[true]]} =
                 Repo.query!(
                   "SELECT $1 = ANY(pg_blocking_pids($2))",
                   [holder_pid, contender_pid]
                 )

        assert_planned_without_audit(ctx.concurrent)
      after
        send(holder.pid, @outcome)
      end

      holder_result = Task.await(holder, 10_000)
      contender_result = Task.await(contender, 10_000)

      if @outcome == :commit do
        assert {:ok, :committed} = holder_result

        assert {:error, {:invalid, "the driver no longer holds a driving role"}} =
                 contender_result

        assert_planned_without_audit(ctx.concurrent)
      else
        assert {:error, :forced_rollback} = holder_result
        assert {:ok, _load} = contender_result
        trip = Ash.get!(Assignment, ctx.concurrent.id, authorize?: false, tenant: ctx.org.id)
        assert {trip.status, trip.version} == {:ACTIVE, 1}
        assert audit_count(ctx.concurrent) == 1
      end
    end
  end

  for terminal <- [:cancel, :complete] do
    @terminal terminal
    test "direct Ash cannot reactivate a #{@terminal} assignment", ctx do
      assert {:ok, _} = Board.transition(ctx.actor, ctx.concurrent.id, "activate", 0)

      assert {:ok, _load} =
               Board.transition(ctx.actor, ctx.concurrent.id, Atom.to_string(@terminal), 1)

      ended = Ash.get!(Assignment, ctx.concurrent.id, authorize?: false, tenant: ctx.org.id)

      assert {:error, _} =
               ended
               |> Ash.Changeset.for_update(:activate, %{})
               |> Ash.update(authorize?: false, tenant: ctx.org.id)

      current = Ash.get!(Assignment, ended.id, authorize?: false, tenant: ctx.org.id)
      assert {current.status, current.version} == {ended.status, 2}
      assert audit_count(current) == 2
      assert {:ok, _} = Board.transition(ctx.actor, ctx.base.id, "activate", 0)
    end
  end

  for column <- ~w(tenant_id load_id operator_participant_id operator_user_id operator_exclusive
                    operator_role_assignment_id operator_role_definition_id) do
    @column column
    test "raw SQL cannot mutate immutable #{@column}", ctx do
      value = mutation_value(ctx, @column)

      assert {:error,
              %Postgrex.Error{
                postgres: %{code: :check_violation, constraint: "assignments_immutable_policy"}
              }} =
               Repo.query("UPDATE assignments SET #{@column}=$2 WHERE id=$1", [
                 uuid(ctx.concurrent.id),
                 value
               ])

      assert_planned_without_audit(ctx.concurrent)
      assert_unchanged_policy(ctx.concurrent)
    end
  end

  test "raw SQL cannot insert an assignment bound to another User", ctx do
    assert {:error,
            %Postgrex.Error{
              postgres: %{
                code: :foreign_key_violation,
                constraint: "assignments_operator_identity_fkey"
              }
            }} = insert_exclusive(ctx, uuid(ctx.dispatcher_user.id))

    assert assignment_count(ctx.org) == 2
  end

  test "raw SQL cannot insert an assignment with a null global User", ctx do
    assert {:error, %Postgrex.Error{postgres: %{code: :not_null_violation}}} =
             insert_exclusive(ctx, nil)

    assert assignment_count(ctx.org) == 2
  end

  test "a legacy concurrent plan cannot become ACTIVE without provenance", ctx do
    assert %{rows: [[id]]} =
             Repo.query!(
               """
               INSERT INTO assignments
                 (tenant_id, load_id, operator_participant_id, operator_user_id,
                  operator_exclusive, starts_at, status)
               SELECT tenant_id, load_id, operator_participant_id, operator_user_id,
                      false, starts_at, 'PLANNED'
               FROM assignments WHERE id=$1 RETURNING id
               """,
               [uuid(ctx.base.id)]
             )

    assert {:error,
            %Postgrex.Error{
              postgres: %{
                code: :check_violation,
                constraint: "assignments_active_concurrent_provenance_check"
              }
            }} = Repo.query("UPDATE assignments SET status='ACTIVE' WHERE id=$1", [id])

    assert %{rows: [["PLANNED", 0, nil, nil]]} =
             Repo.query!(
               """
               SELECT status, version, operator_role_assignment_id, operator_role_definition_id
               FROM assignments WHERE id=$1
               """,
               [id]
             )
  end

  test "raw INSERT meets E3 even without the Ash transition path", ctx do
    assert {:ok, _} = Board.transition(ctx.actor, ctx.concurrent.id, "activate", 0)

    assert {:error, %Postgrex.Error{postgres: %{code: :exclusion_violation}}} =
             insert_exclusive(ctx, uuid(ctx.driver_user.id))

    assert assignment_count(ctx.org) == 2
    assert audit_count(ctx.concurrent) == 1
  end

  defp plan(ctx, role_id) do
    Assignment
    |> Ash.Changeset.for_create(:plan, %{
      tenant_id: ctx.org.id,
      load_id: ctx.base.load_id,
      operator_participant_id: ctx.driver.id,
      starts_at: DateTime.utc_now(),
      operator_role_assignment_id: role_id
    })
    |> Ash.create(authorize?: false, tenant: ctx.org.id)
  end

  defp courier_definition(org) do
    {:ok, manifest} = Dispatch.Access.SeedManifest.fetch("DRIVER")

    RoleDefinition
    |> Ash.Changeset.for_create(:seed, %{
      tenant_id: org.id,
      key: Fixtures.unique("COURIER_POLICY"),
      label: "Concurrent driver",
      capabilities_json: manifest.capabilities,
      constraints_json: manifest.constraints,
      profile_module: inspect(Dispatch.Support.Roles.Courier)
    })
    |> Ash.create!(authorize?: false, tenant: org.id)
  end

  defp mutate_source(ctx, change) do
    {sql, params} =
      case change do
        :revoked ->
          {"UPDATE role_assignments SET status='REVOKED' WHERE id=$1", [uuid(ctx.role.id)]}

        :expired ->
          {"UPDATE role_assignments SET ends_at=now()-interval '1 minute' WHERE id=$1",
           [uuid(ctx.role.id)]}

        :future ->
          {"UPDATE role_assignments SET starts_at=now()+interval '1 hour' WHERE id=$1",
           [uuid(ctx.role.id)]}

        :definition_superseded ->
          {"UPDATE role_definitions SET status='SUPERSEDED' WHERE id=$1",
           [uuid(ctx.definition.id)]}

        :capability_removed ->
          {"UPDATE role_definitions SET capabilities_json=ARRAY[]::text[] WHERE id=$1",
           [uuid(ctx.definition.id)]}

        :mode_changed ->
          {"UPDATE role_definitions SET profile_module=$2 WHERE id=$1",
           [uuid(ctx.definition.id), ctx.driver_role.role_definition.profile_module]}

        :principal_changed ->
          {"UPDATE role_assignments SET principal_id=$2 WHERE id=$1",
           [uuid(ctx.role.id), uuid(ctx.dispatcher.id)]}

        :scope_changed ->
          {"UPDATE role_assignments SET scope_type='STOP', scope_id=$2 WHERE id=$1",
           [uuid(ctx.role.id), uuid(Ash.UUID.generate())]}
      end

    Repo.query!(sql, params)
  end

  defp mutation_value(ctx, "tenant_id"), do: uuid(ctx.dispatcher_user.id)
  defp mutation_value(_ctx, "load_id"), do: uuid(Ash.UUID.generate())
  defp mutation_value(ctx, "operator_participant_id"), do: uuid(ctx.dispatcher.id)
  defp mutation_value(ctx, "operator_user_id"), do: uuid(ctx.dispatcher_user.id)
  defp mutation_value(_ctx, "operator_exclusive"), do: true
  defp mutation_value(ctx, "operator_role_assignment_id"), do: uuid(ctx.driver_role.id)

  defp mutation_value(ctx, "operator_role_definition_id"),
    do: uuid(ctx.driver_role.role_definition_id)

  defp insert_exclusive(ctx, user_id) do
    Repo.query(
      """
      INSERT INTO assignments
        (tenant_id, load_id, operator_participant_id, operator_user_id, operator_exclusive, starts_at, status)
      SELECT tenant_id, load_id, operator_participant_id, $2, true, starts_at, 'ACTIVE'
      FROM assignments WHERE id=$1
      """,
      [uuid(ctx.base.id), user_id]
    )
  end

  defp assert_unchanged_policy(trip) do
    current = Ash.get!(Assignment, trip.id, authorize?: false, tenant: trip.tenant_id)

    for field <- [
          :tenant_id,
          :load_id,
          :operator_participant_id,
          :operator_user_id,
          :operator_exclusive,
          :operator_role_assignment_id,
          :operator_role_definition_id
        ] do
      assert Map.fetch!(current, field) == Map.fetch!(trip, field)
    end
  end

  defp assert_planned_without_audit(trip) do
    current = Ash.get!(Assignment, trip.id, authorize?: false, tenant: trip.tenant_id)
    assert {current.status, current.version} == {:PLANNED, 0}
    assert audit_count(trip) == 0
  end

  defp audit_count(trip) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM audit_events WHERE tenant_id=$1 AND subject_id=$2",
        [uuid(trip.tenant_id), uuid(trip.id)]
      )

    count
  end

  defp assignment_count(org) do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM assignments WHERE tenant_id=$1", [uuid(org.id)])

    count
  end

  defp uuid(id), do: Ecto.UUID.dump!(id)
end
