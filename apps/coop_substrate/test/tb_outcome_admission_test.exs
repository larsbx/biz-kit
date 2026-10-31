defmodule CoopSubstrate.TigerBeetleOutcomeAdmissionTest do
  @moduledoc """
  Real EventStore acceptance for the BizKitOutcomeAdmission formal contract.
  The native verifier is NOT exercised: the fixture is a fixed trusted snapshot.
  All appends, signatures, canonical bytes, races and recovery use production code.
  """
  use CoopSubstrate.LogCase, async: false
  alias CoopSubstrate.{Canonical, Log, OutcomeAdmission}
  alias CoopSubstrate.Protocol.Envelope

  setup do
    verifier = new_member("tb-history-verifier")
    other_key = new_member("tb-history-verifier")
    groups = [group(1, 901), group(2, 17)]
    snapshot = snapshot(groups, [verifier, other_key])
    %{verifier: verifier, other_key: other_key, groups: groups, snapshot: snapshot}
  end

  test "exact-body retry recovers the original signed receipt after appender restart", ctx do
    start_writer(:tb_writer_a, ctx.snapshot)
    [group | _] = ctx.groups
    original_request = outcome(ctx.verifier, group)
    assert {:ok, [receipt]} = Log.append(original_request, :tb_writer_a)
    assert Log.outcome_cursor(OutcomeAdmission.scope(receipt.payload), :tb_writer_a) == 0
    stop_supervised!(:tb_writer_a)
    start_writer(:tb_writer_a, ctx.snapshot)

    # Event ID, signer, signature and timestamp are delivery identities, not slots.
    retry = outcome(ctx.other_key, group, timestamp_ms: original_request.timestamp_ms + 1)
    refute retry.event_id == receipt.event_id
    assert {:ok, [^receipt]} = Log.append(retry, :tb_writer_a)
    assert {:ok, [^receipt]} = Log.read_all()
    assert :ok = Log.verify_chains()
  end

  test "invalid signatures cannot append, recover cached receipts or checkpoint", ctx do
    writer = start_writer(:tb_writer_a, ctx.snapshot)
    [group | _] = ctx.groups
    request = outcome(ctx.verifier, group)

    submitters = [
      fn env -> Log.append(env, :tb_writer_a) end,
      fn env -> Log.append_if([env], {__MODULE__, :allow, []}, :tb_writer_a) end
    ]

    for submit <- submitters do
      assert {:error, {:reject, 0, {:invalid_signature, _}}} = submit.(bad_signature(request))
      assert Log.head(:tb_writer_a).global_seq == 0
    end

    assert {:ok, [receipt]} = Log.append(request, :tb_writer_a)
    retry = outcome(ctx.other_key, group)
    checkpoint_request = checkpoint(ctx.verifier, receipt)

    for submit <- submitters, env <- [retry, checkpoint_request] do
      assert {:error, {:reject, 0, {:invalid_signature, _}}} = submit.(bad_signature(env))
      assert Process.alive?(writer)
      assert Log.head(:tb_writer_a).global_seq == 1
      assert Log.outcome_cursor(OutcomeAdmission.scope(receipt.payload), :tb_writer_a) == 0
    end

    assert {:ok, [^receipt]} = Log.read_all()
    assert {:ok, [^receipt]} = Log.append(retry, :tb_writer_a)
    assert {:ok, [_]} = Log.append(checkpoint_request, :tb_writer_a)
    assert :ok = Log.verify_chains()
  end

  test "changed exact body, native evidence and ordinal fail without durable changes", ctx do
    start_writer(:tb_writer_a, ctx.snapshot)
    [group | _] = ctx.groups
    assert {:ok, [receipt]} = Log.append(outcome(ctx.verifier, group), :tb_writer_a)
    head = Log.head(:tb_writer_a)

    for field <- ~w(outcome native_evidence) do
      changed = Map.put(group, field, bytes(%{"changed" => field}))

      assert {:error, :source_body_conflict} =
               Log.append(outcome(ctx.verifier, changed), :tb_writer_a)
    end

    changed = Map.put(group, "ordinal", 2)
    assert {:error, _} = Log.append(outcome(ctx.verifier, changed), :tb_writer_a)
    assert Log.head(:tb_writer_a) == head
    assert {:ok, [^receipt]} = Log.read_all()
  end

  test "snapshot, pinned signer and receiving destination cannot be chosen by requests", ctx do
    start_writer(:tb_writer_a, ctx.snapshot)
    [group | _] = ctx.groups
    rogue = new_member("tb-history-verifier")

    assert {:error, :unverified_source_outcome} =
             Log.append(outcome(rogue, group), :tb_writer_a)

    assert {:error, :unverified_source_outcome} =
             Log.append(outcome(ctx.verifier, group, destination: "alias"), :tb_writer_a)

    changed = Map.put(group, "outcome", bytes(%{"unverified" => true}))

    assert {:error, :unverified_source_outcome} =
             Log.append(outcome(ctx.verifier, changed), :tb_writer_a)

    assert Log.head(:tb_writer_a).global_seq == 0

    assert {:ok, [_]} = Log.append(outcome(ctx.verifier, group), :tb_writer_a)
    stop_supervised!(:tb_writer_a)

    assert {:error, _} =
             start_supervised(%{
               id: :tb_wrong_destination,
               start:
                 {Log, :start_link,
                  [
                    [
                      name: :tb_wrong_destination,
                      outcome_source_snapshot: %{ctx.snapshot | destination: "alias"}
                    ]
                  ]},
               restart: :temporary
             })

    changed = Map.put(group, "outcome", bytes(%{"changed_snapshot" => true}))
    changed_snapshot = snapshot([changed, Enum.at(ctx.groups, 1)], [ctx.verifier, ctx.other_key])

    assert {:error, _} =
             start_supervised(%{
               id: :tb_wrong_snapshot,
               start:
                 {Log, :start_link,
                  [[name: :tb_wrong_snapshot, outcome_source_snapshot: changed_snapshot]]},
               restart: :temporary
             })

    start_writer(:tb_writer_a, nil)

    assert {:error, :source_admission_disabled} =
             Log.append(outcome(ctx.verifier, group), :tb_writer_a)
  end

  test "multi-verifier envelopes are refused without stopping either Log write API", ctx do
    writer = start_writer(:tb_writer_a, ctx.snapshot)
    [group | _] = ctx.groups
    actors = [ctx.verifier, ctx.other_key]

    request =
      multi_signed_event(
        actors,
        "TigerBeetleOutcomeRecordedV1",
        Map.put(group, "destination", ctx.snapshot.destination),
        chapter_id: group["home"]
      )

    # Generic envelopes permit several distinct keys with the required role.
    # Source admission requires one pinned verifier and must reject this shape
    # as input, while preserving the writer and its durable history.
    assert :ok = Envelope.verify(request)

    submitters = [
      fn env -> Log.append(env, :tb_writer_a) end,
      fn env -> Log.append_if([env], {__MODULE__, :allow, []}, :tb_writer_a) end
    ]

    for submit <- submitters do
      assert {:error, :unverified_source_outcome} = submit.(request)
      assert Process.alive?(writer)
      assert Log.head(:tb_writer_a).global_seq == 0
    end

    assert {:ok, [receipt]} = Log.append(outcome(ctx.verifier, group), :tb_writer_a)
    checkpoint_payload = checkpoint(ctx.verifier, receipt).payload

    checkpoint_request =
      multi_signed_event(actors, "TigerBeetleOutcomeCheckpointedV1", checkpoint_payload,
        chapter_id: group["home"]
      )

    assert :ok = Envelope.verify(checkpoint_request)

    for submit <- submitters, env <- [request, checkpoint_request] do
      assert {:error, :unverified_source_outcome} = submit.(env)
      assert Process.alive?(writer)
      assert Log.head(:tb_writer_a).global_seq == 1
      assert Log.outcome_cursor(OutcomeAdmission.scope(receipt.payload), :tb_writer_a) == 0
    end

    assert {:ok, [^receipt]} = Log.read_all()

    assert {:ok, [checkpoint_receipt]} =
             Log.append(checkpoint(ctx.verifier, receipt), :tb_writer_a)

    assert Log.outcome_cursor(OutcomeAdmission.scope(receipt.payload), :tb_writer_a) == 1
    assert {:ok, [^receipt, ^checkpoint_receipt]} = Log.read_all()
    assert :ok = Log.verify_chains()
  end

  test "out-of-order groups never checkpoint a gap or an unaccepted receipt", ctx do
    start_writer(:tb_writer_a, ctx.snapshot)
    [first, second] = ctx.groups
    assert {:ok, [receipt2]} = Log.append(outcome(ctx.verifier, second), :tb_writer_a)

    assert {:error, :source_prefix_not_durable} =
             Log.append(checkpoint(ctx.verifier, receipt2), :tb_writer_a)

    request1 = outcome(ctx.verifier, first)
    # A signed prospective receipt is not an accepted receipt.
    assert {:error, :source_prefix_not_durable} =
             Log.append(checkpoint(ctx.verifier, request1), :tb_writer_a)

    assert {:error, :source_admission_requires_single_event} =
             Log.append([request1, checkpoint(ctx.verifier, request1)], :tb_writer_a)

    assert {:ok, [receipt1]} = Log.append(request1, :tb_writer_a)
    assert {:ok, [cp1]} = Log.append(checkpoint(ctx.verifier, receipt1), :tb_writer_a)
    assert {:ok, [cp2]} = Log.append(checkpoint(ctx.verifier, receipt2), :tb_writer_a)
    assert {:ok, [^cp1]} = Log.append(checkpoint(ctx.other_key, receipt1), :tb_writer_a)
    assert Log.outcome_cursor(OutcomeAdmission.scope(receipt1.payload), :tb_writer_a) == 2
    stop_supervised!(:tb_writer_a)
    start_writer(:tb_writer_a, ctx.snapshot)
    assert Log.outcome_cursor(OutcomeAdmission.scope(receipt1.payload), :tb_writer_a) == 2
    assert {:ok, [^receipt2, ^receipt1, ^cp1, ^cp2]} = Log.read_all()
  end

  test "same numeric anchors in independent home, cluster and generation scopes", ctx do
    [base | _] = ctx.groups

    variants = [
      base,
      Map.put(base, "home", "other-home"),
      Map.put(base, "cluster", {:bytes, <<2::128>>}),
      Map.put(base, "generation", {:bytes, <<2::64>>})
    ]

    config = snapshot(variants, [ctx.verifier])
    start_writer(:tb_writer_a, config)

    receipts =
      Enum.map(variants, fn group ->
        assert {:ok, [receipt]} = Log.append(outcome(ctx.verifier, group), :tb_writer_a)
        receipt
      end)

    [first | rest] = receipts
    assert {:ok, [_]} = Log.append(checkpoint(ctx.verifier, first), :tb_writer_a)
    assert Log.outcome_cursor(OutcomeAdmission.scope(first.payload), :tb_writer_a) == 1

    for receipt <- rest do
      assert Log.outcome_cursor(OutcomeAdmission.scope(receipt.payload), :tb_writer_a) == 0
    end

    stop_supervised!(:tb_writer_a)
    start_writer(:tb_writer_a, config)

    for receipt <- receipts do
      assert {:ok, [^receipt]} =
               Log.append(
                 outcome(ctx.verifier, Map.drop(receipt.payload, ["destination"])),
                 :tb_writer_a
               )
    end
  end

  test "concurrent stale appenders lose expected-version and rebuild before retry", ctx do
    start_writer(:tb_writer_a, ctx.snapshot)
    start_writer(:tb_writer_b, ctx.snapshot)
    [group | _] = ctx.groups
    parent = self()

    for writer <- [:tb_writer_a, :tb_writer_b] do
      spawn(fn ->
        result =
          try do
            Log.append(outcome(ctx.verifier, group), writer)
          catch
            :exit, reason -> {:call_exit, reason}
          end

        send(parent, {writer, result})
      end)
    end

    assert_receive {writer1, result1}, 15_000
    assert_receive {writer2, result2}, 15_000
    assert Enum.sort([writer1, writer2]) == [:tb_writer_a, :tb_writer_b]
    assert Enum.count([result1, result2], &match?({:ok, [_]}, &1)) == 1
    assert {:error, {:store_append_failed, :wrong_expected_version}} in [result1, result2]
    loser = if match?({:error, _}, result1), do: writer1, else: writer2
    eventually(fn -> Process.whereis(loser) == nil end)
    start_writer(loser, ctx.snapshot)
    assert {:ok, [receipt]} = Log.read_all()
    assert {:ok, [^receipt]} = Log.append(outcome(ctx.other_key, group), loser)
    assert {:ok, [_]} = Log.read_all()
  end

  test "external lookup cannot admit a stale changed-body writer through append_if", ctx do
    start_writer(:tb_writer_a, ctx.snapshot)
    start_writer(:tb_writer_b, ctx.snapshot)
    [group | _] = ctx.groups
    # deliberately stale external lookup
    assert {:ok, []} = Log.read_all()
    assert {:ok, [receipt]} = Log.append(outcome(ctx.verifier, group), :tb_writer_a)
    altered = Map.put(group, "outcome", bytes(%{"stale" => true}))
    # The stale snapshot refuses unknown bytes even before the store race.
    assert {:error, :unverified_source_outcome} =
             Log.append_if(
               [outcome(ctx.verifier, altered)],
               {__MODULE__, :allow, []},
               :tb_writer_b
             )

    assert {:ok, [^receipt]} = Log.read_all()
    assert Log.outcome_cursor(OutcomeAdmission.scope(receipt.payload), :tb_writer_b) == 0
  end

  test "kill after canonical append, before link/reply; recovery repairs links and retains receipt",
       ctx do
    writer = start_writer(:tb_writer_a, ctx.snapshot)
    [first, second] = ctx.groups
    assert {:ok, [_]} = Log.append(outcome(ctx.verifier, first), :tb_writer_a)
    {:ok, lock} = raw_conn()
    Postgrex.query!(lock, "BEGIN", [])

    Postgrex.query!(lock, "SELECT stream_id FROM streams WHERE stream_uuid=$1 FOR UPDATE", [
      first["home"] <> "/tb-outcomes"
    ])

    parent = self()
    monitor = Process.monitor(writer)
    request = outcome(ctx.verifier, second)

    spawn(fn ->
      try do
        send(parent, {:unexpected_reply, Log.append(request, :tb_writer_a)})
      catch
        :exit, reason -> send(parent, {:lost_acknowledgment, reason})
      end
    end)

    try do
      # Canonical ledger reads do not consult the blocked derived stream link.
      eventually(fn -> match?({:ok, [_, _]}, Log.read_all()) end)
      assert {:ok, [receipt1, receipt2]} = Log.read_all()
      Process.exit(writer, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^writer, :killed}, 15_000
      assert_receive {:lost_acknowledgment, _}, 15_000
      refute_receive {:unexpected_reply, _}
      Postgrex.query!(lock, "ROLLBACK", [])
      eventually(fn -> Process.whereis(:tb_writer_a) == nil end)
      start_writer(:tb_writer_a, ctx.snapshot)
      assert {:ok, [^receipt2]} = Log.append(outcome(ctx.other_key, second), :tb_writer_a)
      assert Log.outcome_cursor(OutcomeAdmission.scope(receipt2.payload), :tb_writer_a) == 0
      assert {:ok, [^receipt1, ^receipt2]} = Log.read_stream(first["home"] <> "/tb-outcomes")
      assert {:ok, [_]} = Log.append(checkpoint(ctx.verifier, receipt1), :tb_writer_a)
      assert {:ok, [_]} = Log.append(checkpoint(ctx.verifier, receipt2), :tb_writer_a)
      assert :ok = Log.verify_chains()
    after
      if Process.alive?(writer), do: Process.exit(writer, :kill)
      Postgrex.query!(lock, "ROLLBACK", [])
      GenServer.stop(lock)
    end
  end

  test "independent destinations retain independent cursors in separate durable schemas", ctx do
    [group | _] = ctx.groups
    suffix = String.downcase(CoopSubstrate.ULID.generate())
    schema_a = "tb_sink_a_" <> suffix
    schema_b = "tb_sink_b_" <> suffix
    config_b = %{ctx.snapshot | destination: "eventstore-audit"}

    on_exit(fn ->
      {:ok, conn} = raw_conn()

      for schema <- [schema_a, schema_b],
          do: Postgrex.query!(conn, "DROP SCHEMA IF EXISTS " <> schema <> " CASCADE", [])

      GenServer.stop(conn)
    end)

    receipt_a =
      with_destination_store(schema_a, fn ->
        start_writer(:tb_writer_a, ctx.snapshot)
        assert {:ok, [receipt]} = Log.append(outcome(ctx.verifier, group), :tb_writer_a)
        assert {:ok, [_]} = Log.append(checkpoint(ctx.verifier, receipt), :tb_writer_a)
        stop_supervised!(:tb_writer_a)
        receipt
      end)

    with_destination_store(schema_b, fn ->
      start_writer(:tb_writer_a, config_b)

      assert {:ok, [receipt_b]} =
               Log.append(
                 outcome(ctx.verifier, group, destination: "eventstore-audit"),
                 :tb_writer_a
               )

      assert Log.outcome_cursor(OutcomeAdmission.scope(receipt_b.payload), :tb_writer_a) == 0
      refute receipt_b.payload["destination"] == receipt_a.payload["destination"]
      assert receipt_b.payload["anchor"] == receipt_a.payload["anchor"]
      stop_supervised!(:tb_writer_a)
    end)

    with_destination_store(schema_a, fn ->
      start_writer(:tb_writer_a, ctx.snapshot)
      assert Log.outcome_cursor(OutcomeAdmission.scope(receipt_a.payload), :tb_writer_a) == 1
      assert {:ok, [^receipt_a]} = Log.append(outcome(ctx.other_key, group), :tb_writer_a)
      stop_supervised!(:tb_writer_a)
    end)
  end

  # Each schema is a distinct physical EventStore namespace. A single Log pins
  # one destination; allowing callers to alias one ledger is deliberately refused.
  defp with_destination_store(schema, fun) do
    original = Application.fetch_env!(:coop_substrate, CoopSubstrate.EventStore)
    config = CoopSubstrate.EventStore.config(schema: schema)
    {:ok, conn} = raw_conn()
    Postgrex.query!(conn, "CREATE SCHEMA IF NOT EXISTS " <> schema, [])

    %{rows: [[exists]]} =
      Postgrex.query!(
        conn,
        "SELECT EXISTS(SELECT 1 FROM information_schema.tables WHERE table_schema=$1 AND table_name='events')",
        [schema]
      )

    unless exists, do: EventStore.Storage.Initializer.run!(conn, config)
    GenServer.stop(conn)
    :ok = Supervisor.terminate_child(CoopSubstrate.Supervisor, CoopSubstrate.EventStore)

    Application.put_env(
      :coop_substrate,
      CoopSubstrate.EventStore,
      Keyword.put(original, :schema, schema)
    )

    try do
      {:ok, _} = Supervisor.restart_child(CoopSubstrate.Supervisor, CoopSubstrate.EventStore)
      fun.()
    after
      stop_supervised(:tb_writer_a)
      Supervisor.terminate_child(CoopSubstrate.Supervisor, CoopSubstrate.EventStore)
      Application.put_env(:coop_substrate, CoopSubstrate.EventStore, original)
      {:ok, _} = Supervisor.restart_child(CoopSubstrate.Supervisor, CoopSubstrate.EventStore)
    end
  end

  defp bad_signature(%Envelope{signers: [signer]} = env),
    do: %{env | sigs: Map.put(env.sigs, signer.key_id, <<0::512>>)}

  def allow(_gate), do: :ok

  defp start_writer(name, snapshot) do
    start_supervised!(%{
      id: name,
      start: {Log, :start_link, [[name: name, outcome_source_snapshot: snapshot]]},
      restart: :temporary
    })
  end

  defp group(ordinal, anchor) do
    %{
      "home" => "tb-home",
      "cluster" => {:bytes, <<1::128>>},
      "generation" => {:bytes, <<1::64>>},
      "ordinal" => ordinal,
      "anchor" => {:bytes, <<anchor::128>>},
      "native_transfer_ids" => [{:bytes, <<anchor::128>>}, {:bytes, <<anchor + 1::128>>}],
      "native_evidence" => bytes(%{"original_group" => ordinal, "committed" => true}),
      "outcome" => bytes(%{"operation" => anchor, "status" => "committed"})
    }
  end

  defp snapshot(groups, actors, destination \\ "eventstore-primary") do
    origins = Enum.group_by(groups, fn p -> {p["home"], p["cluster"], p["generation"]} end)
    keys = Map.new(actors, &{&1.signer.key_id, &1.signer.pubkey})

    %{
      destination: destination,
      origins:
        Map.new(origins, fn {origin, groups} ->
          {origin, %{keys: keys, groups: groups}}
        end)
    }
  end

  defp outcome(actor, group, attrs \\ []) do
    destination = Keyword.get(attrs, :destination, "eventstore-primary")

    signed_event(
      actor,
      "TigerBeetleOutcomeRecordedV1",
      Map.put(group, "destination", destination),
      Keyword.put(attrs, :chapter_id, group["home"])
    )
  end

  defp checkpoint(actor, receipt) do
    {:ok, hash} = Envelope.event_hash(receipt)

    payload =
      receipt.payload
      |> Map.take(~w(home destination cluster generation ordinal anchor))
      |> Map.put("outcome_event_hash", {:bytes, hash})

    signed_event(actor, "TigerBeetleOutcomeCheckpointedV1", payload,
      chapter_id: receipt.chapter_id
    )
  end

  defp bytes(term) do
    {:ok, bytes} = Canonical.encode(term)
    {:bytes, bytes}
  end

  defp eventually(fun, remaining \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, remaining) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(20)
          eventually(fun, remaining - 1)
        )
  end
end
