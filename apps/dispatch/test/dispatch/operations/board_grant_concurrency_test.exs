defmodule Dispatch.Operations.BoardGrantConcurrencyTest do
  use ExUnit.Case, async: false

  alias Dispatch.Access.Actor
  alias Dispatch.Operations.Board
  alias Dispatch.Repo
  alias Dispatch.Support.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :integration

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    org = Fixtures.carrier()
    %{user: user, participant: person} = Fixtures.person(org.id, org)
    actor = Fixtures.actor(org.id, org, person, "DISPATCHER")
    trip = Fixtures.assignment_record(org.id, org, person)

    on_exit(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      for table <-
            ~w(outbox_events audit_events assignments loads role_assignments role_definitions participants) do
        Repo.query!("DELETE FROM #{table} WHERE tenant_id = $1", [uuid(org.id)])
      end

      Repo.query!("DELETE FROM users WHERE id = $1", [uuid(user.id)])
      Repo.query!("DELETE FROM organizations WHERE id = $1", [uuid(org.id)])
      Sandbox.checkin(Repo)
    end)

    %{actor: actor, trip: trip, org: org, person: person, user: user}
  end

  test "a revocation committed while the transition waits denies mutation", ctx do
    before = snapshot(ctx)

    assert {:error, :forbidden} =
             queued(ctx, fn -> Fixtures.revoke(ctx.org.id, ctx.actor.role_assignment) end)

    assert snapshot(ctx) == before
  end

  for change <- [
        :deactivate,
        :expire,
        :supersede,
        :retire,
        :remove_capability,
        :constrain,
        :narrow_scope
      ] do
    @change change
    test "committed #{@change} during a trip lock wait denies mutation", ctx do
      before = snapshot(ctx)
      assert {:error, :forbidden} = queued(ctx, fn -> change_grant(ctx, @change) end)
      assert snapshot(ctx) == before
    end
  end

  test "another live assignment never rescues the revoked selection", ctx do
    alternate = second_dispatcher(ctx)
    assert Actor.can?(alternate, "assignment.update.status")
    before = snapshot(ctx)

    assert {:error, :forbidden} =
             queued(ctx, fn -> Fixtures.revoke(ctx.org.id, ctx.actor.role_assignment) end)

    assert snapshot(ctx) == before
    assert {:ok, _} = Board.transition(alternate, ctx.trip.id, "activate", ctx.trip.version)
    assert audit_role(ctx) == alternate.role_assignment.id
  end

  test "revoking an unselected role preserves the selected unchanged grant", ctx do
    alternate = second_dispatcher(ctx)
    old_at = DateTime.add(DateTime.utc_now(), -300, :second)
    ctx = %{ctx | actor: %{ctx.actor | at: old_at}}

    assert {:ok, _} =
             queued(ctx, fn -> Fixtures.revoke(ctx.org.id, alternate.role_assignment) end)

    assert audit_role(ctx) == ctx.actor.role_assignment.id

    %{rows: [[status, version, at]]} =
      Repo.query!(
        "SELECT a.status, a.version, e.occurred_at FROM assignments a JOIN audit_events e ON e.subject_id = a.id WHERE a.id = $1",
        [uuid(ctx.trip.id)]
      )

    assert {status, version} == {"ACTIVE", ctx.trip.version + 1}
    assert NaiveDateTime.compare(at, DateTime.to_naive(old_at)) == :gt
  end

  test "denial preserves pre-existing audit history as well as trip state", ctx do
    assert {:ok, _} = Board.create_load(ctx.actor, %{"commodity_text" => "Existing audit"})
    before = snapshot(ctx)
    assert elem(before, 1) != []

    assert {:error, :forbidden} =
             queued(ctx, fn -> Fixtures.revoke(ctx.org.id, ctx.actor.role_assignment) end)

    assert snapshot(ctx) == before
  end

  test "a stale actor snapshot is denied even without a lock wait", ctx do
    Fixtures.revoke(ctx.org.id, ctx.actor.role_assignment)
    assert Actor.can?(ctx.actor, "assignment.update.status")
    before = snapshot(ctx)

    assert {:error, :forbidden} =
             Board.transition(ctx.actor, ctx.trip.id, "activate", ctx.trip.version)

    assert snapshot(ctx) == before
  end

  test "a captured token expires while waiting for the trip lock", ctx do
    expires = DateTime.add(DateTime.utc_now(), 2, :second)

    ctx = %{
      ctx
      | actor: %{
          ctx.actor
          | authentication: %{subject: ctx.user.oidc_subject, expires_at: expires}
        }
    }

    before = snapshot(ctx)

    assert {:error, :forbidden} =
             queued(ctx, fn ->
               Process.sleep(
                 max(
                   DateTime.to_unix(expires, :millisecond) - System.system_time(:millisecond) + 1,
                   0
                 )
               )

               assert DateTime.compare(DateTime.utc_now(), expires) != :lt
             end)

    assert snapshot(ctx) == before
  end

  test "an unchanged authenticated grant succeeds", ctx do
    expires = DateTime.add(DateTime.utc_now(), 300, :second)

    ctx = %{
      ctx
      | actor: %{
          ctx.actor
          | authentication: %{subject: ctx.user.oidc_subject, expires_at: expires}
        }
    }

    assert {:ok, _} = queued(ctx, fn -> :unchanged end)
    assert audit_role(ctx) == ctx.actor.role_assignment.id
  end

  test "snapshot principal, tenant and organization cannot replace the selected context", ctx do
    for actor <- [
          %{ctx.actor | principal_id: Ash.UUID.generate()},
          %{ctx.actor | principal_type: :SERVICE},
          %{ctx.actor | tenant_id: Ash.UUID.generate()},
          %{
            ctx.actor
            | role_assignment: %{ctx.actor.role_assignment | organization_id: Ash.UUID.generate()}
          }
        ] do
      before = snapshot(ctx)
      assert {:error, reason} = Board.transition(actor, ctx.trip.id, "activate", ctx.trip.version)
      assert reason in [:forbidden, :not_found]
      assert snapshot(ctx) == before
    end
  end

  for ending <- [:logout, :expiry, :unbind] do
    @ending ending
    test "Identity #{@ending} committed while waiting denies an HTTP-originated actor", ctx do
      Dispatch.Support.PortalIdentity.setup()
      token = Dispatch.Support.PortalIdentity.token_for(ctx.user.oidc_subject)
      on_exit(fn -> BizKit.Identity.logout(token) end)
      {:ok, claims} = Dispatch.Identity.Tokens.BizKitSession.verify(token)

      conn =
        Plug.Test.conn(:post, "/v1/operations")
        |> Plug.Conn.assign(:oidc_claims, claims)
        |> DispatchWeb.Plugs.ResolveActor.call([])

      refute conn.halted
      actor = conn.assigns.actor
      assert actor.authentication.session_reference == BizKit.Identity.Sessions.reference(token)
      ctx = %{ctx | actor: actor}
      before = snapshot(ctx)
      assert {:error, :forbidden} = queued(ctx, fn -> end_session(token, @ending) end)
      assert snapshot(ctx) == before
    end
  end

  for changing <- [:assignment, :definition] do
    @changing changing
    test "ordinary #{@changing} updates wait until an admitted transition commits", ctx do
      parent = self()

      writer =
        session(fn ->
          Repo.transaction(fn ->
            assert {:ok, load} =
                     Board.transition(ctx.actor, ctx.trip.id, "activate", ctx.trip.version)

            send(parent, {:admitted, backend()})
            receive do: (:release -> load)
          end)
        end)

      assert_receive {:admitted, writer_backend}, 5_000

      changer =
        session(fn ->
          send(parent, {:changer, backend()})

          if @changing == :assignment do
            Fixtures.revoke(ctx.org.id, ctx.actor.role_assignment)
          else
            change_grant(ctx, :remove_capability)
          end
        end)

      assert_receive {:changer, changer_backend}, 5_000

      try do
        assert blocked_by?(changer_backend, writer_backend)
      after
        send(writer.pid, :release)
      end

      assert {:ok, _} = Task.await(writer, 10_000)
      Task.await(changer, 10_000)
      assert audit_role(ctx) == ctx.actor.role_assignment.id
      assert {:error, :forbidden} = Board.transition(ctx.actor, ctx.trip.id, "cancel", nil)
    end
  end

  defp end_session(token, :logout), do: BizKit.Identity.logout(token)
  defp end_session(_token, :unbind), do: Application.put_env(:biz_kit_identity, :bindings, [])

  defp end_session(token, :expiry) do
    :sys.replace_state(BizKit.Cluster.Singleton.name(BizKit.Identity.Sessions), fn state ->
      key = {false, :crypto.hash(:sha256, token)}
      true = :ets.update_element(BizKit.Identity.Sessions, key, {4, 0})
      state
    end)
  end

  defp second_dispatcher(ctx) do
    original = ctx.actor.role_assignment.role_definition

    definition =
      Dispatch.Accounts.RoleDefinition
      |> Ash.Changeset.for_create(:seed, %{
        tenant_id: ctx.org.id,
        key: "DISPATCHER-SECOND",
        label: "Second dispatcher",
        capabilities_json: original.capabilities_json,
        constraints_json: original.constraints_json,
        profile_module: original.profile_module
      })
      |> Ash.create!(authorize?: false, tenant: ctx.org.id)

    Fixtures.actor(ctx.org.id, ctx.org, ctx.person, "DISPATCHER-SECOND",
      definition: definition,
      scope_type: :ORGANIZATION
    )
  end

  defp change_grant(ctx, :deactivate), do: update_assignment(ctx, "status = 'EXPIRED'")
  defp change_grant(ctx, :expire), do: update_assignment(ctx, "ends_at = clock_timestamp()")
  defp change_grant(ctx, :narrow_scope), do: update_assignment(ctx, "scope_type = 'SELF'")

  defp change_grant(ctx, :supersede) do
    ctx.actor.role_assignment.role_definition
    |> Ash.Changeset.for_update(:supersede, %{})
    |> Ash.update!(authorize?: false, tenant: ctx.org.id)
  end

  defp change_grant(ctx, :retire), do: update_definition(ctx, "status = 'RETIRED'")

  defp change_grant(ctx, :remove_capability),
    do:
      update_definition(
        ctx,
        "capabilities_json = array_remove(capabilities_json, 'assignment.update.status')"
      )

  defp change_grant(ctx, :constrain),
    do:
      update_definition(
        ctx,
        ~s|constraints_json = jsonb_set(constraints_json, '{assignment.update.status}', '["requires_consent"]'::jsonb)|
      )

  # SQL mutations cover defensive reads even for definition edits that the
  # current public Ash action deliberately does not expose.
  defp update_assignment(ctx, set) do
    Repo.query!("UPDATE role_assignments SET #{set} WHERE id = $1 AND tenant_id = $2", [
      uuid(ctx.actor.role_assignment.id),
      uuid(ctx.org.id)
    ])
  end

  defp update_definition(ctx, set) do
    Repo.query!("UPDATE role_definitions SET #{set} WHERE id = $1 AND tenant_id = $2", [
      uuid(ctx.actor.role_assignment.role_definition_id),
      uuid(ctx.org.id)
    ])
  end

  defp audit_role(ctx) do
    %{rows: [[id]]} =
      Repo.query!("SELECT role_assignment_id FROM audit_events WHERE tenant_id = $1", [
        uuid(ctx.org.id)
      ])

    Ecto.UUID.load!(id)
  end

  # The holder does no authorization: revocation must be able to COMMIT while
  # the requester is blocked on the trip. Sharing sandbox sessions would hide
  # this bug. PostgreSQL's wait graph, not elapsed time, establishes the order.
  defp queued(ctx, change) do
    parent = self()
    before = snapshot(ctx)
    assert Actor.can?(ctx.actor, "assignment.update.status")

    holder =
      session(fn ->
        Repo.transaction(fn ->
          Repo.query!("SELECT id FROM assignments WHERE id = $1 FOR UPDATE", [uuid(ctx.trip.id)])
          send(parent, {:held, backend()})
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive {:held, holder_backend}, 5_000

    requester =
      session(fn ->
        send(parent, {:requester, backend()})
        Board.transition(ctx.actor, ctx.trip.id, "activate", ctx.trip.version)
      end)

    assert_receive {:requester, requester_backend}, 5_000

    try do
      assert blocked_by?(requester_backend, holder_backend),
             "requester must pass preflight and reach the assignment row lock"

      revoker =
        session(fn ->
          result = change.()
          {backend(), result}
        end)

      {revoker_backend, _} = Task.await(revoker, 10_000)

      assert length(Enum.uniq([holder_backend, requester_backend, revoker_backend, backend()])) ==
               4

      assert snapshot(ctx) == before
    after
      send(holder.pid, :release)
    end

    assert {:ok, :ok} = Task.await(holder, 10_000)
    Task.await(requester, 10_000)
  end

  defp snapshot(ctx) do
    {
      Repo.query!("SELECT status, version, ends_at FROM assignments WHERE id = $1", [
        uuid(ctx.trip.id)
      ]).rows,
      Repo.query!(
        "SELECT row_to_json(a)::text FROM audit_events a WHERE tenant_id = $1 ORDER BY id",
        [uuid(ctx.org.id)]
      ).rows
    }
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

  defp uuid(id), do: Ecto.UUID.dump!(id)
  defp backend, do: Repo.query!("SELECT pg_backend_pid()").rows |> hd() |> hd()

  defp blocked_by?(requester, holder, attempts \\ 200)
  defp blocked_by?(_requester, _holder, 0), do: false

  defp blocked_by?(requester, holder, attempts) do
    %{rows: [[blocked]]} =
      Repo.query!("SELECT $1 = ANY(pg_blocking_pids($2))", [holder, requester])

    if blocked do
      true
    else
      Process.sleep(10)
      blocked_by?(requester, holder, attempts - 1)
    end
  end
end
