defmodule CoopSubstrate.WriterFence do
  @moduledoc """
  The retirement cutover fence for a legacy writer: the ledger orders it, the
  legacy writer's own database enforces it.

  1. Governance signs `LegacyWriterFenced` (`writer`, `reason`) and the Log
     admits it, only for a writer in the closed set `writers/0` and only in a
     chapter whose governance key is declared (no bootstrap mode). Nothing
     unfences a writer, so the order is irreversible on the ledger.
  2. `install/3` reads that event back from the ledger and, in ONE transaction
     on the legacy database, records it in `biz_kit_writer_fence` and puts a
     statement trigger refusing INSERT, UPDATE, DELETE and TRUNCATE on every
     table outside the system schemas, the fence table included. Creating a
     trigger waits for writers already holding the table, so every write
     either committed before the fence or is refused after it: no instant has
     two writers. It fences every writer of that database, whichever
     repository deployed it, which a flag in one copy of the code could not.

  Not fenced: DDL, and the database owner, who can drop the triggers. A
  rollback is therefore a deliberate act by the owner, outside this module;
  re-running `install/3` restores the fence and covers tables created since.
  """

  alias CoopSubstrate.Log
  alias CoopSubstrate.Protocol.{Envelope, TypeRegistry}

  @type_name "LegacyWriterFenced"
  @writers ~w(eatsbot)
  @trigger "biz_kit_writer_fence"
  @function "public.biz_kit_refuse_fenced_write"

  @doc "The writers a fence may name."
  def writers, do: @writers

  def event_types do
    %{
      @type_name => %{
        required_roles: ["governance"],
        disclosure_class: :commons,
        stream: {:payload_field, "writer-fences", "writer"},
        payload: %{required: %{"writer" => :string, "reason" => :string}, optional: %{}}
      }
    }
  end

  @doc "Append-gate check: a known writer, in a chapter with declared governance."
  def check(%Envelope{chapter_id: chapter, payload: %{"writer" => writer}}, gate) do
    cond do
      writer not in @writers -> {:error, {:unknown_writer, writer}}
      map_size(gate.role_keys[{chapter, "governance"}] || %{}) == 0 -> {:error, :no_governance}
      true -> :ok
    end
  end

  @doc "Sign and append the fence order with a governance signer."
  def declare(chapter, writer, reason, signer) do
    with {:ok, env} <-
           Envelope.new(%{
             chapter_id: chapter,
             type: @type_name,
             payload: %{"writer" => writer, "reason" => reason},
             signers: [Map.take(signer, [:role, :key_id, :pubkey])],
             timestamp_ms: System.system_time(:millisecond)
           }),
         {:ok, env} <- Envelope.sign(env, signer.key_id, signer.seed) do
      Log.append(env)
    end
  end

  @doc "The admitted fence order for `writer` in `chapter`, if any."
  def order(chapter, writer) do
    with {:ok, stream} <- TypeRegistry.stream_id(@type_name, chapter, %{"writer" => writer}),
         {:ok, [first | _]} <- Log.read_stream(stream) do
      {:ok, first}
    else
      {:ok, []} -> {:error, :not_ordered}
      error -> error
    end
  end

  @doc """
  Install the fence on the legacy database `conn_opts` (Postgrex options),
  once the ledger holds the order. Idempotent.
  """
  def install(chapter, writer, conn_opts) do
    with {:ok, env} <- order(chapter, writer),
         {:ok, conn} <- Postgrex.start_link(conn_opts) do
      try do
        Postgrex.transaction(conn, &fence!(&1, env), timeout: :infinity)
      rescue
        error in Postgrex.Error -> {:error, error}
      after
        GenServer.stop(conn)
      end
    end
  end

  defp fence!(conn, env) do
    Postgrex.query!(
      conn,
      """
      CREATE TABLE IF NOT EXISTS public.biz_kit_writer_fence (
        writer text PRIMARY KEY, chapter_id text NOT NULL, event_id text NOT NULL,
        fenced_at timestamptz NOT NULL DEFAULT now())
      """,
      []
    )

    %{rows: recorded} =
      Postgrex.query!(conn, "SELECT 1 FROM public.biz_kit_writer_fence WHERE writer = $1", [
        env.payload["writer"]
      ])

    if recorded == [] do
      Postgrex.query!(
        conn,
        "INSERT INTO public.biz_kit_writer_fence (writer, chapter_id, event_id) VALUES ($1, $2, $3)",
        [env.payload["writer"], env.chapter_id, env.event_id]
      )
    end

    Postgrex.query!(
      conn,
      """
      CREATE OR REPLACE FUNCTION #{@function}() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'writes to % are fenced: this writer was cut over on the ledger', TG_TABLE_NAME
          USING ERRCODE = 'insufficient_privilege';
      END $$
      """,
      []
    )

    # Replacing the trigger lets a re-run cover tables created since without
    # stacking triggers.
    Postgrex.query!(
      conn,
      """
      CREATE OR REPLACE FUNCTION pg_temp.biz_kit_fence_all() RETURNS integer LANGUAGE plpgsql AS $$
      DECLARE t text; n integer := 0;
      BEGIN
        FOR t IN SELECT format('%I.%I', schemaname, tablename) FROM pg_tables
                 WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
                   AND schemaname NOT LIKE 'pg\\_%' LOOP
          EXECUTE format('DROP TRIGGER IF EXISTS #{@trigger} ON %s', t);
          EXECUTE format('CREATE TRIGGER #{@trigger} BEFORE INSERT OR UPDATE OR DELETE OR TRUNCATE ' ||
                         'ON %s FOR EACH STATEMENT EXECUTE FUNCTION #{@function}()', t);
          n := n + 1;
        END LOOP;
        RETURN n;
      END $$
      """,
      []
    )

    %{rows: [[tables]]} = Postgrex.query!(conn, "SELECT pg_temp.biz_kit_fence_all()", [])
    %{writer: env.payload["writer"], event_id: env.event_id, tables: tables}
  end
end
