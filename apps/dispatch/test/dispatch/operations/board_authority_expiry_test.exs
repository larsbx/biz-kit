defmodule Dispatch.Operations.BoardAuthorityExpiryTest do
  @moduledoc """
  Issue #296: authority that lapses after transaction admission, while an
  activation waits on the E3 occupancy constraint.

  Row locks order database changes to authority around the transaction. They
  do not stop a clock, and they do not reach the Identity session store. So an
  activation can pass every check, wait on another transaction's uncommitted
  ACTIVE row, and commit after its grant, token or session has ended.

  Whether that commit is acceptable is an undecided governance policy. Each
  scenario is therefore stated once under each candidate, selected by tag:

    * `temporal_policy:admission`: authority at transaction admission
      suffices. This characterizes the merged runtime.
    * `temporal_policy:commit`: authority must still hold when the wait
      ends. This is expected to fail until the runtime revalidates.

  The `:integration` controls are independent of that choice.

  The holder is a raw occupancy writer. It takes no authority, audit or
  second-trip lock, so the contender's only wait is the unique index, which it
  reaches only after admission. Wall-clock scenarios cannot be driven without
  sleeping, because the runtime reads `DateTime.utc_now/0` directly; each run
  instead proves its own ordering from observed blocking, and fails as
  inconclusive rather than passing if admission came after the lapse.
  """
  use ExUnit.Case, async: false

  import Dispatch.Support.ConcurrentSessions, only: [session: 1, backend: 0, blockers: 2]

  alias Dispatch.Access.Actor
  alias Dispatch.Accounts.RoleAssignment
  alias Dispatch.Fleet.Assignment
  alias Dispatch.Operations.Board
  alias Dispatch.Repo
  alias Dispatch.Support.{ConcurrentSessions, Fixtures, PortalIdentity}
  alias Ecto.Adapters.SQL.Sandbox

  @lead_ms 3_000
  @clock_bounded [:actor_grant_expiry, :operator_grant_expiry, :token_expiry]
  @session_bounded [:session_expiry, :session_logout]

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    org = Fixtures.carrier()
    %{user: user, participant: dispatcher} = Fixtures.person(org.id, org)
    %{user: driver_user, participant: driver} = Fixtures.person(org.id, org)
    on_exit(fn -> ConcurrentSessions.cleanup(org, [user, driver_user]) end)

    %{org: org, user: user, dispatcher: dispatcher, driver: driver}
  end

  for scenario <- @clock_bounded ++ @session_bounded, policy <- [:admission, :commit] do
    @scenario scenario
    @policy policy
    @tag temporal_policy: policy
    test "#{scenario} during the occupancy wait, #{policy}-time authority", ctx do
      ctx = arrange(ctx, @scenario)
      run = blocked_activation(ctx, fn _contender -> lapse(ctx, @scenario) end)

      assert DateTime.compare(run.admitted_by, run.during) == :lt,
             "inconclusive: the activation was not seen admitted before the lapse"

      assert DateTime.compare(run.during, run.still_blocked_at) != :gt,
             "inconclusive: the lapse was not seen before the wait ended"

      expect(@policy, ctx, run)
    end
  end

  describe "independent of the temporal policy" do
    @describetag :integration

    test "an unchanged authority activates once the occupancy holder rolls back", ctx do
      ctx = arrange(ctx, :unchanged)
      run = blocked_activation(ctx, fn _contender -> :unchanged end)

      assert {:ok, _load} = run.result
      assert_activated(ctx, run)
    end

    test "an idempotency key bounds the occupancy wait and commits nothing", ctx do
      ctx = arrange(ctx, :unchanged)

      keyed = fn ->
        Dispatch.Idempotency.execute(ctx.actor, Ecto.UUID.generate(), %{}, fn ->
          with {:ok, _load} <- transition(ctx), do: {:ok, 200, %{}}
        end)
      end

      run = blocked_activation(ctx, fn _contender -> :held end, write: keyed, bounded: true)

      # The refusal's shape is reported in AUTHORITY_EXPIRY_V1.md, not fixed here.
      assert {:error, _refused} = run.result
      assert DateTime.diff(run.still_blocked_at, run.admitted_by, :millisecond) in 2_000..4_000
      assert {:PLANNED, ctx.wanted.version, []} == outcome(ctx)
    end

    for source <- [:grant, :operator_grant] do
      @source source
      test "a database revocation of the #{source} waits behind the blocked activation", ctx do
        ctx = arrange(ctx, :unchanged)
        parent = self()

        run =
          blocked_activation(ctx, fn contender ->
            revoker =
              session(fn ->
                send(parent, {:revoker, backend()})
                Fixtures.revoke(ctx.org.id, Map.fetch!(ctx, @source))
              end)

            assert_receive {:revoker, revoker_backend}, 5_000

            assert blockers(revoker_backend, nil) == [contender],
                   "the revocation must wait on the admitted activation's share lock"

            assert status(ctx, @source) == :ACTIVE
            revoker
          end)

        assert {:ok, _load} = run.result
        assert %RoleAssignment{status: :REVOKED} = Task.await(run.during, 10_000)
        assert_activated(ctx, run)

        # Authority is refused before occupancy is consulted.
        assert {:error, next_refusal(@source)} ==
                 Board.transition(ctx.actor, ctx.held.id, "activate", ctx.held.version)
      end
    end
  end

  defp next_refusal(:grant), do: :forbidden

  defp next_refusal(:operator_grant),
    do: {:invalid, "the driver no longer holds a driving role"}

  # The governing instant for each candidate policy, applied to one observed run.
  defp expect(:admission, ctx, run) do
    assert {:ok, _load} = run.result
    assert_activated(ctx, run)
  end

  defp expect(:commit, ctx, run) do
    assert {:error, _refused} = run.result
    assert {:PLANNED, ctx.wanted.version, []} == outcome(ctx)
  end

  # The audit names the selected grant at its admission instant, which precedes
  # everything that happened during the wait.
  defp assert_activated(ctx, run) do
    assert {:ACTIVE, version, [{role_assignment_id, occurred_at}]} = outcome(ctx)
    assert version == ctx.wanted.version + 1
    assert role_assignment_id == ctx.grant.id
    assert NaiveDateTime.compare(occurred_at, DateTime.to_naive(run.admitted_by)) == :lt
  end

  defp arrange(ctx, scenario) do
    horizon = DateTime.add(DateTime.utc_now(), @lead_ms, :millisecond)
    bound = fn bounded -> if scenario == bounded, do: [ends_at: horizon], else: [] end
    grant = grant(ctx, ctx.dispatcher, "DISPATCHER", bound.(:actor_grant_expiry))
    operator_grant = grant(ctx, ctx.driver, "DRIVER", bound.(:operator_grant_expiry))

    [held, wanted] =
      for _ <- 1..2, do: Fixtures.assignment_record(ctx.org.id, ctx.org, ctx.driver)

    {:ok, actor} = Actor.from_assignment(grant)

    ctx
    |> Map.merge(%{
      grant: grant,
      operator_grant: operator_grant,
      held: held,
      wanted: wanted,
      horizon: horizon
    })
    |> authenticate(actor, scenario)
  end

  defp grant(ctx, participant, key, opts),
    do: Fixtures.assignment(ctx.org.id, ctx.org, participant, key, opts)

  defp authenticate(ctx, actor, :token_expiry) do
    authentication = %{subject: ctx.user.oidc_subject, expires_at: ctx.horizon}
    Map.put(ctx, :actor, %{actor | authentication: authentication})
  end

  # The actor an HTTP request resolves, carrying its session reference.
  defp authenticate(ctx, _actor, scenario) when scenario in @session_bounded do
    PortalIdentity.setup()
    token = PortalIdentity.token_for(ctx.user.oidc_subject)
    on_exit(fn -> BizKit.Identity.logout(token) end)
    {:ok, claims} = Dispatch.Identity.Tokens.BizKitSession.verify(token)

    conn =
      Plug.Test.conn(:post, "/v1/operations")
      |> Plug.Conn.assign(:oidc_claims, claims)
      |> DispatchWeb.Plugs.ResolveActor.call([])

    refute conn.halted
    assert is_binary(conn.assigns.actor.authentication.session_reference)
    Map.merge(ctx, %{actor: conn.assigns.actor, token: token})
  end

  defp authenticate(ctx, actor, _scenario), do: Map.put(ctx, :actor, actor)

  # Ends the scenario's authority and answers the instant from which it is gone.
  defp lapse(ctx, scenario) when scenario in @clock_bounded do
    Process.sleep(max(DateTime.diff(ctx.horizon, DateTime.utc_now(), :millisecond), 0) + 50)
    ctx.horizon
  end

  defp lapse(ctx, :session_logout) do
    BizKit.Identity.logout(ctx.token)
    DateTime.utc_now()
  end

  defp lapse(ctx, :session_expiry) do
    # Inside the owning singleton, so the session's own deadline is in the past
    # without a wall-clock sleep.
    :sys.replace_state(BizKit.Cluster.Singleton.name(BizKit.Identity.Sessions), fn state ->
      key = {false, :crypto.hash(:sha256, ctx.token)}
      true = :ets.update_element(BizKit.Identity.Sessions, key, {4, 0})
      state
    end)

    DateTime.utc_now()
  end

  # Holds occupancy for the driver's User, lets the activation of `wanted`
  # reach the index behind it, runs `during`, then rolls the holder back so the
  # activation's own outcome depends only on its authority.
  defp blocked_activation(ctx, during, opts \\ []) do
    parent = self()
    write = Keyword.get(opts, :write, fn -> transition(ctx) end)

    holder =
      session(fn ->
        Repo.transaction(fn ->
          %{num_rows: 1} =
            Repo.query!("UPDATE assignments SET status = 'ACTIVE' WHERE id = $1", [
              Ecto.UUID.dump!(ctx.held.id)
            ])

          send(parent, {:holding, backend()})

          receive do
            :release -> Repo.rollback(:released)
          after
            15_000 -> Repo.rollback(:test_barrier_timeout)
          end
        end)
      end)

    assert_receive {:holding, holder_backend}, 5_000

    contender =
      session(fn ->
        send(parent, {:contender, backend()})
        write.()
      end)

    observed =
      try do
        assert_receive {:contender, contender_backend}, 5_000

        assert blockers(contender_backend, "transactionid") == [holder_backend],
               "the admitted activation must wait on the occupancy constraint"

        admitted_by = DateTime.utc_now()
        outcome = during.(contender_backend)

        # A bounded write must end by itself while the holder still holds.
        result =
          if opts[:bounded] do
            Task.await(contender, 10_000)
          else
            assert blockers(contender_backend, "transactionid") == [holder_backend],
                   "the activation must still be waiting after the change"

            nil
          end

        %{
          admitted_by: admitted_by,
          during: outcome,
          still_blocked_at: DateTime.utc_now(),
          result: result
        }
      after
        send(holder.pid, :release)
      end

    assert {:error, :released} = Task.await(holder, 10_000)
    Map.update!(observed, :result, &(&1 || Task.await(contender, 10_000)))
  end

  defp transition(ctx),
    do: Board.transition(ctx.actor, ctx.wanted.id, "activate", ctx.wanted.version)

  defp outcome(ctx) do
    trip = Ash.get!(Assignment, ctx.wanted.id, authorize?: false, tenant: ctx.org.id)

    %{rows: audits} =
      Repo.query!(
        """
        SELECT role_assignment_id::text, occurred_at FROM audit_events
        WHERE tenant_id = $1 AND subject_id = $2 ORDER BY occurred_at
        """,
        Enum.map([ctx.org.id, ctx.wanted.id], &Ecto.UUID.dump!/1)
      )

    {trip.status, trip.version, Enum.map(audits, &List.to_tuple/1)}
  end

  defp status(ctx, source) do
    Ash.get!(RoleAssignment, Map.fetch!(ctx, source).id, authorize?: false, tenant: ctx.org.id).status
  end
end
