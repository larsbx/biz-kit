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

