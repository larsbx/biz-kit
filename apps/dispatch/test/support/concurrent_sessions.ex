defmodule Dispatch.Support.ConcurrentSessions do
  @moduledoc """
  Independently committed PostgreSQL sessions for lock-interleaving tests.

  A shared sandbox connection serializes calls in the test harness and cannot
  demonstrate a row lock, so each session checks out its own unsandboxed
  connection and every statement it runs commits for the others to see.
  """

  alias Dispatch.Repo
  alias Ecto.Adapters.SQL.Sandbox

  @doc "Runs `fun` in a task on its own committed connection."
  @spec session((-> term())) :: Task.t()
  def session(fun) do
    Task.async(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      try do
        fun.()
      after
        Sandbox.checkin(Repo)
      end
    end)
  end

  @doc "This connection's PostgreSQL backend pid."
  @spec backend() :: integer()
  def backend, do: Repo.query!("SELECT pg_backend_pid()").rows |> hd() |> hd()

  @doc "Takes the row lock an ordinary trip UPDATE also takes."
  @spec lock_trip(%{id: Ash.UUID.t()}) :: Postgrex.Result.t()
  def lock_trip(trip) do
    Repo.query!("SELECT id FROM assignments WHERE id = $1 FOR UPDATE", [Ecto.UUID.dump!(trip.id)])
  end

  @doc "Whether some session is blocked on a lock `backend` holds, polled for up to 2.5 s."
  @spec waiting_on?(integer(), non_neg_integer()) :: boolean()
  def waiting_on?(backend, attempts \\ 100)
  def waiting_on?(_backend, 0), do: false

  def waiting_on?(backend, attempts) do
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

  @doc "Deletes everything a board test created in `org`'s tenant, then `users`."
  @spec cleanup(%{id: Ash.UUID.t()}, [%{id: Ash.UUID.t()}]) :: :ok
  def cleanup(org, users) do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    tenant = Ecto.UUID.dump!(org.id)

    for table <- ~w(outbox_events audit_events consent_grants stops assignments loads
                    vehicles trailers role_assignments role_definitions participants) do
      Repo.query!("DELETE FROM #{table} WHERE tenant_id = $1", [tenant])
    end

    for user <- users,
        do: Repo.query!("DELETE FROM users WHERE id = $1", [Ecto.UUID.dump!(user.id)])

    Repo.query!("DELETE FROM organizations WHERE id = $1", [tenant])
    Sandbox.checkin(Repo)
  end
end
