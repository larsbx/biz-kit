defmodule CoopSubstrate.LogCase do
  @moduledoc """
  Case template for tests that exercise the canonical log: resets the event
  store schema and restarts the `CoopSubstrate.Log` appender before each
  test, and provides signed-envelope builders plus raw-SQL tamper helpers
  (the acceptance tests must forge history as the database superuser and
  prove the chains catch it).
  """

  use ExUnit.CaseTemplate

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias CoopSubstrate.Crypto
  alias CoopSubstrate.Protocol.Envelope

  using do
    quote do
      import CoopSubstrate.LogCase

      setup :reset_log
    end
  end

  def reset_log(context) do
    truncate_store!()
    restart_log()

    # Check on the way out as well as resetting on the way in. Resetting only
    # on entry means the last test to run leaves its ledger behind, and a
    # forged record there is not stale-data noise: `Log.recover/0` folds the
    # whole ledger during application start and raises on the first undecodable
    # record, so the next run cannot boot — and `reset_log` never gets to run to
    # clear it. This attributes the breakage to the test that caused it; the
    # `after_suite` hook in `test/test_helper.exs` clears the store once at the
    # end (truncating per-test would double the suite's reset cost for nothing,
    # since the next test's setup truncates anyway).
    on_exit(fn ->
      unless context[:tampers_ledger], do: assert_ledger_intact!()
    end)

    :ok
  end

  @doc "Truncate the event store back to an empty, initialised state."
  def truncate_store! do
    {:ok, conn} = raw_conn()

    Postgrex.transaction(conn, fn conn ->
      Postgrex.query!(conn, "SET LOCAL eventstore.reset TO 'on'", [])

      Postgrex.query!(
        conn,
        "TRUNCATE TABLE snapshots, subscriptions, stream_events, streams, events RESTART IDENTITY",
        []
      )

      Postgrex.query!(
        conn,
        "INSERT INTO streams (stream_id, stream_uuid, stream_version) VALUES (0, '$all', 0)",
        []
      )
    end)

    GenServer.stop(conn)
    :ok
  end

  @doc """
  Fail the test that leaves a ledger the application cannot boot against.

  A test that forges history must not hand that history to the next run. Tests
  which deliberately end on a forged ledger declare `@tag :tampers_ledger`;
  the exception has to be stated, not assumed.
  """
  def assert_ledger_intact! do
    CoopSubstrate.Log.read_all()
    :ok
  rescue
    error ->
      reraise("""
              this test left a ledger the application cannot boot against:

                  #{Exception.message(error)}

              `CoopSubstrate.Log.recover/0` folds the entire ledger during
              application start and raises on the first undecodable record, so
              this residue makes the next run unstartable — and the reset that
              would clear it never gets to run.

              If the forged state is deliberate, declare it: `@tag :tampers_ledger`.
              """, __STACKTRACE__)
  end

  def restart_log do
    :ok = Supervisor.terminate_child(CoopSubstrate.Supervisor, CoopSubstrate.Log)
    {:ok, _pid} = Supervisor.restart_child(CoopSubstrate.Supervisor, CoopSubstrate.Log)
    :ok
  end

  @doc "A direct superuser connection, outside the event store's pool."
  def raw_conn do
    config = Application.fetch_env!(:coop_substrate, CoopSubstrate.EventStore)

    Postgrex.start_link(Keyword.take(config, [:hostname, :port, :username, :password, :database]))
  end

  @doc "Run `fun` with delete protection bypassed (superuser forgery)."
  def with_delete_bypass(fun) do
    {:ok, conn} = raw_conn()

    result =
      Postgrex.transaction(conn, fn conn ->
        Postgrex.query!(conn, "SET LOCAL eventstore.enable_hard_deletes TO 'on'", [])
        fun.(conn)
      end)

    GenServer.stop(conn)
    result
  end

  @doc "Run `fun` with the events UPDATE trigger disabled (superuser forgery)."
  def with_update_bypass(fun) do
    {:ok, conn} = raw_conn()
    Postgrex.query!(conn, "ALTER TABLE events DISABLE TRIGGER no_update_events", [])

    try do
      fun.(conn)
    after
      Postgrex.query!(conn, "ALTER TABLE events ENABLE TRIGGER no_update_events", [])
      GenServer.stop(conn)
    end
  end

  # -- envelope builders --------------------------------------------------------

  @doc "A fresh member: `%{seed: seed, signer: %{role:, pubkey:, key_id:}}`."
  def new_member(role \\ "author", key_id \\ nil) do
    {pubkey, seed} = Crypto.generate_keypair()
    key_id = key_id || "k-" <> Base.encode16(binary_part(pubkey, 0, 4), case: :lower)
    %{seed: seed, signer: %{role: role, pubkey: pubkey, key_id: key_id}}
  end

  @doc "A fully signed envelope of any registered type."
  def signed_event(member, type, payload, attrs \\ []) do
    attrs = Map.new(attrs)

    {:ok, envelope} =
      Envelope.new(%{
        chapter_id: Map.get(attrs, :chapter_id, "chapter-genesis"),
        type: type,
        payload: payload,
        signers: [member.signer],
        auth_ref: Map.get(attrs, :auth_ref),
        timestamp_ms: Map.get(attrs, :timestamp_ms, System.system_time(:millisecond))
      })

    {:ok, signed} = Envelope.sign(envelope, member.signer.key_id, member.seed)
    signed
  end

  @doc "A fully signed envelope with several signers (multi-role types)."
  def multi_signed_event(actors, type, payload, attrs \\ []) when is_list(actors) do
    attrs = Map.new(attrs)

    {:ok, envelope} =
      Envelope.new(%{
        chapter_id: Map.get(attrs, :chapter_id, "chapter-genesis"),
        type: type,
        payload: payload,
        signers: Enum.map(actors, & &1.signer),
        auth_ref: Map.get(attrs, :auth_ref),
        timestamp_ms: Map.get(attrs, :timestamp_ms, System.system_time(:millisecond))
      })

    Enum.reduce(actors, envelope, fn actor, env ->
      {:ok, signed} = Envelope.sign(env, actor.signer.key_id, actor.seed)
      signed
    end)
  end

  @doc "MemberRegistered payload for an actor created with `new_member(\"member\")`."
  def registration_payload(member_id, actor) do
    %{
      "member_id" => member_id,
      "pubkey" => {:bytes, actor.signer.pubkey},
      "key_id" => actor.signer.key_id
    }
  end

  @doc """
  Register the entity and member (skippable via `register_entity:` /
  `register_member:` when they already exist) and advance the membership to
  `to:` (`:invited | :probationary | :member`, default `:member`).
  """
  def seed_membership!(steward, member, member_id, entity_id, opts \\ []) do
    chapter = Keyword.get(opts, :chapter_id, "chapter-genesis")
    class = Keyword.get(opts, :class, "carriers_coop")
    to = Keyword.get(opts, :to, :member)
    mp = %{"member_id" => member_id, "entity_id" => entity_id}

    if Keyword.get(opts, :register_entity, true) do
      {:ok, _} =
        CoopSubstrate.Log.append(
          signed_event(
            steward,
            "EntityRegistered",
            %{"entity_id" => entity_id, "class" => class},
            chapter_id: chapter
          )
        )
    end

    if Keyword.get(opts, :register_member, true) do
      {:ok, _} =
        CoopSubstrate.Log.append(
          signed_event(member, "MemberRegistered", registration_payload(member_id, member),
            chapter_id: chapter
          )
        )
    end

    [
      invited:
        signed_event(steward, "MembershipInvited", Map.put(mp, "class", class),
          chapter_id: chapter
        ),
      probationary:
        signed_event(member, "MembershipProbationStarted", mp, chapter_id: chapter),
      member:
        multi_signed_event([member, steward], "MembershipConfirmed", mp, chapter_id: chapter)
    ]
    |> Enum.reduce_while(:ok, fn {state, env}, :ok ->
      {:ok, _} = CoopSubstrate.Log.append(env)
      if state == to, do: {:halt, :ok}, else: {:cont, :ok}
    end)
  end

  @doc "A fully signed TestProjectionEvent envelope."
  def signed_test_event(member, attrs \\ []) do
    attrs = Map.new(attrs)

    {:ok, envelope} =
      Envelope.new(%{
        chapter_id: Map.get(attrs, :chapter_id, "chapter-genesis"),
        type: "TestProjectionEvent",
        payload:
          Map.get(attrs, :payload, %{
            "note" => Map.get(attrs, :note, "test"),
            "amount_minor" => Map.get(attrs, :amount_minor, 100)
          }),
        signers: [member.signer],
        timestamp_ms: Map.get(attrs, :timestamp_ms, System.system_time(:millisecond))
      })

    {:ok, signed} = Envelope.sign(envelope, member.signer.key_id, member.seed)
    signed
  end
end
