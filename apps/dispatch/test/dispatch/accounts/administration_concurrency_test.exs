defmodule Dispatch.Accounts.AdministrationConcurrencyTest do
  @moduledoc """
  True two-connection tests of role administration and concurrent revocation.

  The ordinary sandbox sharing mode cannot demonstrate PostgreSQL row-lock
  ordering. These integration tests use separately committed SQL connections,
  as the location concurrency tests do, and observe actual blocking PIDs.
  """

  use ExUnit.Case, async: false

  alias Dispatch.Accounts.Administration
  alias Dispatch.Repo
  alias Dispatch.Support.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :integration

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    org = Fixtures.carrier()
    %{user: admin_user, participant: admin} = Fixtures.person(org.id, org)
    %{user: driver_user, participant: driver} = Fixtures.person(org.id, org)

    actor = Fixtures.actor(org.id, org, admin, "ADMIN")
    driver_definition = Fixtures.role_definition(org.id, "DRIVER")

    on_exit(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)
      tenant = Ecto.UUID.dump!(org.id)

      for table <- [
            "audit_events",
            "outbox_events",
            "idempotency_records",
            "role_assignments",
            "role_definitions",
            "participants"
          ] do
        Repo.query!("DELETE FROM #{table} WHERE tenant_id = $1", [tenant])
      end

      for user <- [admin_user, driver_user] do
        Repo.query!("DELETE FROM users WHERE id = $1", [Ecto.UUID.dump!(user.id)])
      end

      Repo.query!("DELETE FROM organizations WHERE id = $1", [tenant])
      Sandbox.checkin(Repo)
    end)

    %{org: org, actor: actor, driver: driver, driver_definition: driver_definition}
  end

  test "revocation committed while admission waits cannot authorize a new grant", ctx do
    parent = self()

    holder =
      session(fn ->
        Repo.transaction(fn ->
          Repo.query!(
            """
            UPDATE role_assignments SET status = 'REVOKED', ends_at = clock_timestamp()
            WHERE id = $1
            """,
            [Ecto.UUID.dump!(ctx.actor.role_assignment.id)]
          )

          send(parent, {:held_revocation, backend()})

          receive do
            :commit_revocation -> :ok
          after
            10_000 -> Repo.rollback(:holder_timeout)
          end
        end)
      end)

    assert_receive {:held_revocation, holder_backend}, 5_000

    requester =
      session(fn ->
        Administration.grant(
          ctx.actor,
          %{
            "participant_id" => ctx.driver.id,
            "role_definition_id" => ctx.driver_definition.id
          },
          DateTime.utc_now()
        )
      end)

    try do
      assert waiting_on?(holder_backend),
             "administrator must wait for in-flight role revocation before admission"
    after
      send(holder.pid, :commit_revocation)
    end

    assert {:ok, :ok} = Task.await(holder, 10_000)
    assert {:error, :not_found} = Task.await(requester, 10_000)

    assert %{rows: [[0]]} =
             Repo.query!(
               """
               SELECT count(*) FROM role_assignments
               WHERE tenant_id = $1 AND principal_id = $2 AND status = 'ACTIVE'
               """,
               [Ecto.UUID.dump!(ctx.org.id), Ecto.UUID.dump!(ctx.driver.id)]
             )

    assert %{rows: [[0]]} =
             Repo.query!(
               "SELECT count(*) FROM audit_events WHERE tenant_id = $1",
               [Ecto.UUID.dump!(ctx.org.id)]
             )
  end

  test "organization suspension committed while admission waits denies the grant", ctx do
    parent = self()

    holder =
      session(fn ->
        Repo.transaction(fn ->
          Repo.query!(
            "UPDATE organizations SET status = 'SUSPENDED' WHERE id = $1",
            [Ecto.UUID.dump!(ctx.org.id)]
          )

          send(parent, {:held_suspension, backend()})

          receive do
            :commit_suspension -> :ok
          after
            10_000 -> Repo.rollback(:holder_timeout)
          end
        end)
      end)

    assert_receive {:held_suspension, holder_backend}, 5_000

    requester =
      session(fn ->
        Administration.grant(
          ctx.actor,
          %{
            "participant_id" => ctx.driver.id,
            "role_definition_id" => ctx.driver_definition.id
          },
          DateTime.utc_now()
        )
      end)

    try do
      assert waiting_on?(holder_backend),
             "administrator must await organization suspension before admission"
    after
      send(holder.pid, :commit_suspension)
    end

    assert {:ok, :ok} = Task.await(holder, 10_000)
    assert {:error, :not_found} = Task.await(requester, 10_000)
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
