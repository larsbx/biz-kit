defmodule CoopSubstrate.SignedEventReplayTest do
  @moduledoc """
  Real signed Log -> audited source -> EventReplay -> PostgreSQL acceptance.
  No synthetic verified source, backend adapter or production subscriber.
  """
  use CoopSubstrate.LogCase, async: false

  alias AgentOpsStore.{EventCursor, EventEffects, EventReplay}
  alias CoopSubstrate.{Canonical, Log, SignedConsumerSource}
  alias CoopSubstrate.Protocol.Envelope

  @cursor_sql Path.expand("../../../deploy/agent-core/sql/004_event_cursor.sql", __DIR__)
  @scope %{"tenant_id" => "replay-tenant", "project_id" => "replay-project"}

  defmodule StagingHost do
    def environment, do: :staging
    def event_consumer_context, do: {:ok, Process.get(:signed_replay_context)}
  end

  defmodule ProductionHost do
    def environment, do: :production
    def event_consumer_context, do: raise("production must refuse before reading context")
  end

  setup_all do
    # Use the canonical test database, with its existing EventStore schemas.
    # psql's simple protocol applies the exact checked-in multi-statement DDL.
    config = Application.fetch_env!(:coop_substrate, CoopSubstrate.EventStore)
    {:ok, conn} = raw_conn()
    Postgrex.query!(conn, "CREATE SCHEMA IF NOT EXISTS agent_ops", [])
    GenServer.stop(conn)

    {output, status} =
      System.cmd("psql", ["--no-psqlrc", "--set=ON_ERROR_STOP=1", "--file", @cursor_sql],
        stderr_to_stdout: true,
        env: [
          {"PGHOST", Keyword.fetch!(config, :hostname)},
          {"PGPORT", to_string(Keyword.fetch!(config, :port))},
          {"PGUSER", Keyword.fetch!(config, :username)},
          {"PGPASSWORD", Keyword.get(config, :password) || ""},
          {"PGDATABASE", Keyword.fetch!(config, :database)}
        ]
      )

    assert status == 0, "cursor fixture migration failed: #{output}"
    :ok
  end

  setup do
    suffix = CoopSubstrate.ULID.generate()

    context = %{
      home_id: "signed-home-" <> suffix,
      consumer_id: "signed-replay-" <> suffix,
      source: SignedConsumerSource,
      ignored_types: ["RoleKeyDeclared", "TaskOperatorGrantedV1", "TestProjectionEvent"]
    }

    Process.put(:signed_replay_context, context)
    config = Application.fetch_env!(:coop_substrate, CoopSubstrate.EventStore)

    conn =
      start_supervised!(
        {Postgrex, Keyword.take(config, [:hostname, :port, :username, :password, :database])}
      )

    on_exit(fn ->
      {:ok, cleanup} = raw_conn()

      for table <- ["consumer_effects", "consumer_processed", "consumer_cursors"] do
        Postgrex.query!(
          cleanup,
          "DELETE FROM agent_ops.#{table} WHERE home_id=$1 AND consumer_id=$2",
          [context.home_id, context.consumer_id]
        )
      end

      GenServer.stop(cleanup)
    end)

    %{conn: conn, context: context}
  end

  test "signed candidate and no-op receipts survive a killed caller and fresh SQL/log sessions",
       ctx do
    events = signed_history!()
    [_, _, offboard, _] = events
    parent = self()

    {worker, monitor} =
      spawn_monitor(fn ->
        Process.put(:signed_replay_context, ctx.context)
        {:ok, conn} = raw_conn()

        {:ok, %{to: 3, processed: 3, has_more: true}} =
          EventReplay.drain(conn, StagingHost, max_events: 3)

        # The caller has committed its page but has not returned progress to
        # a scheduler. Kill it here; recovery must use SQL, not this process.
        send(parent, {:page_committed, self()})

        receive do
          :finish -> :ok
        end
      end)

    on_exit(fn -> Process.exit(worker, :kill) end)
    assert_receive {:page_committed, ^worker}, 15_000
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 15_000

    stop_supervised!(Postgrex)
    restart_log()
    {:ok, fresh} = raw_conn()

    try do
      assert {:ok, 3} = watermark(fresh, ctx.context)

      assert {:ok, %{from: 3, to: 4, processed: 1, has_more: false}} =
               EventReplay.drain(fresh, StagingHost, max_events: 1)

      assert {:ok, %{from: 4, to: 4, processed: 0, has_more: false}} =
               EventReplay.drain(fresh, StagingHost)

      assert_receipts(fresh, ctx.context, events)

      assert {:ok, effects} =
               EventEffects.derive(offboard, ignored_types: ctx.context.ignored_types)

      assert {:ok, %{cursor: 4, disposition: :existing}} =
               EventCursor.commit(fresh, descriptor(ctx.context, offboard, effects))

      %{rows: rows} =
        Postgrex.query!(
          fresh,
          "SELECT effect_id, effect_kind FROM agent_ops.consumer_effects " <>
            "WHERE home_id=$1 AND consumer_id=$2",
          [ctx.context.home_id, ctx.context.consumer_id]
        )

      assert rows == [["agent-reconcile:" <> offboard.event_id, "principal-offboarding"]]
      assert :ok = Log.verify_chains()
    after
      GenServer.stop(fresh)
    end
  end

  test "a valid but unreviewed signed event halts after the safe prefix until policy review",
       ctx do
    member = new_member()
    {:ok, [first]} = Log.append(signed_test_event(member))
    gov = new_member("governance")
    {:ok, [second]} = Log.append(governance_declaration(gov))
    Process.put(:signed_replay_context, %{ctx.context | ignored_types: ["TestProjectionEvent"]})

    assert {:error, :event_type_not_reviewed} = EventReplay.drain(ctx.conn, StagingHost)
    assert {:ok, 1} = watermark(ctx.conn, ctx.context)
    assert_receipts(ctx.conn, ctx.context, [first])

    Process.put(:signed_replay_context, ctx.context)
    assert {:ok, %{from: 1, to: 2, processed: 1}} = EventReplay.drain(ctx.conn, StagingHost)
    assert_receipts(ctx.conn, ctx.context, [first, second])
  end

  test "forged signature is refused by admission and cannot create an operational receipt", ctx do
    member = new_member()
    signed = signed_test_event(member)
    forged = %{signed | sigs: %{member.signer.key_id => <<0::512>>}}

    assert {:error, {:reject, 0, {:invalid_signature, _}}} = Log.append(forged)

    assert {:ok, %{from: 0, to: 0, processed: 0, has_more: false}} =
             EventReplay.drain(ctx.conn, StagingHost)

    assert {:ok, 0} = watermark(ctx.conn, ctx.context)
    assert_receipts(ctx.conn, ctx.context, [])
  end

  @tag :tampers_ledger
  test "stored signature tampering fails the real prefix audit before the next SQL commit", ctx do
    member = new_member()

    {:ok, [first, second]} =
      Log.append([
        signed_test_event(member, note: "first"),
        signed_test_event(member, note: "second")
      ])

    assert {:ok, %{to: 1, processed: 1, has_more: true}} =
             EventReplay.drain(ctx.conn, StagingHost, max_events: 1)

    {:ok, original} = Canonical.encode(Envelope.full_record_term(second))
    forged = %{second | sigs: %{member.signer.key_id => <<0::512>>}}
    {:ok, corrupted} = Canonical.encode(Envelope.full_record_term(forged))

    try do
      replace_record!(2, corrupted)
      assert {:error, :unverified_ledger_prefix} = SignedConsumerSource.verified_head()
      assert {:error, :unverified_ledger_prefix} = EventReplay.drain(ctx.conn, StagingHost)
      assert {:ok, 1} = watermark(ctx.conn, ctx.context)
      assert_receipts(ctx.conn, ctx.context, [first])
    after
      replace_record!(2, original)
    end

    assert :ok = Log.verify_chains()
    assert {:ok, %{from: 1, to: 2, processed: 1}} = EventReplay.drain(ctx.conn, StagingHost)
    assert_receipts(ctx.conn, ctx.context, [first, second])
  end

  test "production refuses before database access or trusted host context" do
    assert {:error, :staging_only} = EventReplay.drain(:not_a_connection, ProductionHost)
  end

  defp signed_history! do
    gov = new_member("governance")
    operator = new_member("operator")
    {:ok, [declaration]} = Log.append(governance_declaration(gov))

    grant =
      signed_event(
        gov,
        "TaskOperatorGrantedV1",
        Map.merge(@scope, %{
          "principal_id" => "replay-operator",
          "key_id" => operator.signer.key_id,
          "pubkey" => {:bytes, operator.signer.pubkey}
        })
      )

    {:ok, [accepted_grant]} = Log.append(grant)

    offboard =
      signed_event(
        gov,
        "TaskPrincipalOffboardedV1",
        Map.put(@scope, "principal_id", "replay-operator")
      )

    {:ok, [accepted_offboard]} = Log.append(offboard)
    {:ok, [noop]} = Log.append(signed_test_event(new_member()))
    [declaration, accepted_grant, accepted_offboard, noop]
  end

  defp governance_declaration(gov) do
    signed_event(gov, "RoleKeyDeclared", %{
      "role" => "governance",
      "key_id" => gov.signer.key_id,
      "pubkey" => {:bytes, gov.signer.pubkey}
    })
  end

  defp watermark(conn, context),
    do: EventCursor.watermark(conn, context.home_id, context.consumer_id)

  defp descriptor(context, event, effects) do
    {:ok, digest} = Envelope.event_hash(event)

    %{
      home_id: context.home_id,
      consumer_id: context.consumer_id,
      global_seq: event.global_seq,
      event_id: event.event_id,
      event_digest: {:bytes, digest},
      effects: effects
    }
  end

  defp assert_receipts(conn, context, events) do
    %{rows: rows} =
      Postgrex.query!(
        conn,
        "SELECT global_seq, event_id, event_digest, effect_bundle " <>
          "FROM agent_ops.consumer_processed WHERE home_id=$1 AND consumer_id=$2 ORDER BY global_seq",
        [context.home_id, context.consumer_id]
      )

    expected =
      Enum.map(events, fn event ->
        {:ok, digest} = Envelope.event_hash(event)
        {:ok, effects} = EventEffects.derive(event, ignored_types: context.ignored_types)
        bundle = Enum.map(effects, &%{"effect_id" => &1.effect_id, "kind" => &1.kind})
        [event.global_seq, event.event_id, digest, bundle]
      end)

    assert rows == expected
  end

  defp replace_record!(seq, bytes) do
    with_update_bypass(fn conn ->
      %{num_rows: 1} =
        Postgrex.query!(
          conn,
          "UPDATE events SET data=$1 WHERE event_id IN " <>
            "(SELECT event_id FROM stream_events WHERE stream_id=" <>
            "(SELECT stream_id FROM streams WHERE stream_uuid='ledger') AND stream_version=$2)",
          [bytes, seq]
        )
    end)
  end
end
