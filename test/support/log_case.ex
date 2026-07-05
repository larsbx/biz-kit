defmodule CoopSubstrate.LogCase do
  @moduledoc """
  Case template for tests that exercise the canonical log: resets the event
  store schema and restarts the `CoopSubstrate.Log` appender before each
  test, and provides signed-envelope builders plus raw-SQL tamper helpers
  (the acceptance tests must forge history as the database superuser and
  prove the chains catch it).
  """

  use ExUnit.CaseTemplate

  alias CoopSubstrate.Crypto
  alias CoopSubstrate.Protocol.Envelope

  using do
    quote do
      import CoopSubstrate.LogCase

      setup :reset_log
    end
  end

  def reset_log(_context) do
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
    restart_log()
    :ok
  end

  def restart_log do
    :ok = Supervisor.terminate_child(CoopSubstrate.Supervisor, CoopSubstrate.Log)
    {:ok, _pid} = Supervisor.restart_child(CoopSubstrate.Supervisor, CoopSubstrate.Log)
    :ok
  end

  @doc "A direct superuser connection, outside the event store's pool."
  def raw_conn do
    config = Application.fetch_env!(:coop_substrate, CoopSubstrate.EventStore)

    Postgrex.start_link(
      hostname: config[:hostname],
      port: config[:port],
      username: config[:username],
      database: config[:database]
    )
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
