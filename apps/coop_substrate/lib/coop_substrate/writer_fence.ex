defmodule CoopSubstrate.WriterFence do
  @moduledoc """
  The retirement cutover fence for a legacy writer: the ledger orders it, the
  legacy writer's own database enforces it.

  1. Governance signs `LegacyWriterFenced` (`writer`, `reason`) and the Log
     admits it, only for a writer in the closed set `writers/0` and only in a
     chapter whose governance key is declared (no bootstrap mode). A writer
     with a history specification requires an earlier admitted archive record
     in the same chapter. Nothing unfences a writer, so the order is irreversible
     on the ledger.
  2. `install/4` reads that event back from the ledger, verifies the selected
     archive where required, and, in ONE transaction on the legacy database,
     records it in `biz_kit_writer_fence` and puts a
     statement trigger refusing INSERT, UPDATE, DELETE and TRUNCATE on every
     table outside the system schemas, the fence table included. Creating a
     trigger waits for writers already holding the table, so every write
     either committed before the fence or is refused after it. It fences every
     ordinary writer of that database, whichever repository deployed it, which
     a flag in one copy of the code could not.

  A writer whose history is kept requires `archive`, `manifest_sha256` and
  `archive_event_id` options. `CoopSubstrate.HistoryArchive.preflight/3` reopens
  the files and matches that exact archive record in a verified ledger prefix.
  Its selected fence event must match the order's chapter, writer, identity,
  and canonical position used for installation. The legacy three-argument
  API cannot bypass this check.

  The archive's source hostname and database must match the actual connection
  options; the caller cannot override those expected labels. This is a label
  comparison, not authentication of a database instance. Successful installation
  returns the archive verification evidence alongside its fence result.

  The existing signed fence schema does not bind one archive digest. Source
  quiescence or a final-delta procedure, durable archive custody, and activating
  the successor only after fence commit remain operational requirements.

  A writer's database may also hold tables another app still writes, which
  the fence leaves writable (`exempt/1`): SpruceGoose's holds the task host's
  native sessions (docs/architecture/2026-11-09-task-host.md).

  Not fenced: DDL, and the database owner, who can drop the triggers. A
  rollback is therefore a deliberate act by the owner, outside this module;
  re-running `install/4` restores the fence and covers tables created since.
  """

  alias CoopSubstrate.{HistoryArchive, Log}
  alias CoopSubstrate.Protocol.{Envelope, TypeRegistry}

  @type_name "LegacyWriterFenced"
  # Each fenceable writer, with the `public` tables in its database that other
  # apps still write and the fence leaves alone. SpruceGoose's task rows,
  # certified events and actor registry share the fenced database on Mama.
  @writers %{
    "eatsbot" => [],
    "spruce_goose" => ~w(identity_native_sessions schema_migrations)
  }
  @trigger "biz_kit_writer_fence"
  @function "public.biz_kit_refuse_fenced_write"

  @doc "The writers a fence may name."
  def writers, do: @writers |> Map.keys() |> Enum.sort()

  @doc "The tables a writer's fence leaves writable."
  def exempt(writer), do: Map.fetch!(@writers, writer)

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

  @doc "Append-gate check: known writer, declared governance, and any required prior archive."
  def check(%Envelope{chapter_id: chapter, payload: %{"writer" => writer}}, gate) do
    cond do
      not Map.has_key?(@writers, writer) -> {:error, {:unknown_writer, writer}}
      map_size(gate.role_keys[{chapter, "governance"}] || %{}) == 0 -> {:error, :no_governance}
      true -> check_prior_archive(gate, chapter, writer)
    end
  end

  defp check_prior_archive(gate, chapter, writer) do
    archived = Map.get(gate, :legacy_archived_writers, MapSet.new())

    if HistoryArchive.spec(writer) == nil or MapSet.member?(archived, {chapter, writer}),
      do: :ok,
      else: {:error, :history_not_archived}
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
         {:ok, [first | _]} <- Log.read_stream(stream),
         :ok <- check_order_scope(first, chapter, writer) do
      {:ok, first}
    else
      {:ok, []} -> {:error, :not_ordered}
      error -> error
    end
  end

  # A derived link stream is a locator, not proof that its first decoded
  # record belongs to the requested order. Validate the scope for all writers.
  @doc false
  def check_order_scope(
        %Envelope{type: @type_name, chapter_id: chapter, payload: %{"writer" => writer}},
        chapter,
        writer
      )
      when is_binary(chapter) and chapter != "" and is_map_key(@writers, writer),
      do: :ok

  def check_order_scope(_env, _chapter, _writer), do: {:error, :fence_order_mismatch}

  @doc """
  Install the fence on the legacy database `conn_opts` (Postgrex options),
  once the ledger holds the order. Idempotent for that exact chapter and order.
  History-bearing writers require `:archive`, `:manifest_sha256`, and
  `:archive_event_id`; files and ledger binding are rechecked before connecting
  to the legacy database. Writers without a history specification need no options.
  """
  def install(chapter, writer, conn_opts, opts \\ []) do
    with {:ok, env} <- order(chapter, writer),
         {:ok, archive_opts} <- archive_options(writer, conn_opts, opts),
         {:ok, evidence} <- HistoryArchive.preflight(chapter, writer, archive_opts),
         :ok <- check_preflight_order(env, evidence),
         {:ok, conn} <- Postgrex.start_link(conn_opts) do
      try do
        Postgrex.transaction(
          conn,
          fn transaction ->
            fence!(transaction, env) |> Map.put(:archive_verification, evidence)
          end,
          timeout: :infinity
        )
      rescue
        error in Postgrex.Error -> {:error, error}
      after
        GenServer.stop(conn)
      end
    end
  end

  defp archive_options(writer, conn_opts, opts) do
    cond do
      HistoryArchive.spec(writer) == nil ->
        {:ok, opts}

      not (is_list(conn_opts) and Keyword.keyword?(conn_opts) and
             is_list(opts) and Keyword.keyword?(opts)) ->
        {:error, :archive_source_required}

      true ->
        hostname = Keyword.get(conn_opts, :hostname, "localhost")
        database = Keyword.get(conn_opts, :database)

        if is_binary(hostname) and hostname != "" and is_binary(database) and database != "" do
          source = %{"hostname" => hostname, "database" => database}
          {:ok, Keyword.put(opts, :expected_source, source)}
        else
          {:error, :archive_source_required}
        end
    end
  end

  @doc false
  def check_preflight_order(
        %Envelope{type: @type_name, payload: %{"writer" => writer}},
        :no_history_required
      ) do
    if Map.has_key?(@writers, writer) and HistoryArchive.spec(writer) == nil,
      do: :ok,
      else: {:error, :fence_order_mismatch}
  end

  # The envelope came from the link stream; only this independent evidence
  # was selected from the verified canonical prefix. Match every identity
  # field consumed by fence!/2 as well as the canonical position.
  def check_preflight_order(
        %Envelope{
          type: @type_name,
          event_id: id,
          chapter_id: chapter,
          global_seq: sequence,
          payload: %{"writer" => writer}
        },
        %{
          fence_event_id: id,
          chapter_id: chapter,
          writer: writer,
          fence_global_seq: sequence
        }
      )
      when is_binary(id) and id != "" and is_integer(sequence) and sequence > 0,
      do: :ok

  def check_preflight_order(_env, _evidence), do: {:error, :fence_order_mismatch}

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
      Postgrex.query!(
        conn,
        "SELECT chapter_id, event_id FROM public.biz_kit_writer_fence WHERE writer = $1 FOR UPDATE",
        [env.payload["writer"]]
      )

    expected_chapter = env.chapter_id
    expected_event = env.event_id

    case recorded do
      [] ->
        Postgrex.query!(
          conn,
          "INSERT INTO public.biz_kit_writer_fence (writer, chapter_id, event_id) VALUES ($1, $2, $3)",
          [env.payload["writer"], expected_chapter, expected_event]
        )

      [[^expected_chapter, ^expected_event]] ->
        :ok

      rows ->
        Postgrex.rollback(
          conn,
          {:fence_order_conflict,
           %{
             writer: env.payload["writer"],
             expected: %{chapter_id: expected_chapter, event_id: expected_event},
             recorded: rows
           }}
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
    # stacking triggers; an exempt table loses any trigger an earlier run put
    # on it.
    Postgrex.query!(
      conn,
      """
      CREATE OR REPLACE FUNCTION pg_temp.biz_kit_fence_all(exempt text[]) RETURNS integer
      LANGUAGE plpgsql AS $$
      DECLARE r record; n integer := 0;
      BEGIN
        FOR r IN SELECT format('%I.%I', schemaname, tablename) AS t,
                        schemaname = 'public' AND tablename = ANY(exempt) AS free
                 FROM pg_tables
                 WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
                   AND schemaname NOT LIKE 'pg\\_%' LOOP
          EXECUTE format('DROP TRIGGER IF EXISTS #{@trigger} ON %s', r.t);
          IF NOT r.free THEN
            EXECUTE format('CREATE TRIGGER #{@trigger} BEFORE INSERT OR UPDATE OR DELETE OR TRUNCATE ' ||
                           'ON %s FOR EACH STATEMENT EXECUTE FUNCTION #{@function}()', r.t);
            n := n + 1;
          END IF;
        END LOOP;
        RETURN n;
      END $$
      """,
      []
    )

    %{rows: [[tables]]} =
      Postgrex.query!(conn, "SELECT pg_temp.biz_kit_fence_all($1)", [
        exempt(env.payload["writer"])
      ])

    %{writer: env.payload["writer"], event_id: env.event_id, tables: tables}
  end
end
