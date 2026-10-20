defmodule CoopSubstrate.Records do
  @moduledoc """
  Operational records: the durable bookkeeping of the server itself, which
  is never the ledger (docs/architecture/2026-10-20-durable-quota.md). Today,
  the evidence quota's charges (`ArtifactCustody.Quota`).

  Same database as the ledger's store, in a schema of its own (`records`),
  so `CoopSubstrate.EventStore` keeps its rule: only `CoopSubstrate.Log`
  appends there. Nothing here is signed, chained or exported; a record is
  an Erlang term (`Records.Serializer`).
  """

  use EventStore, otp_app: :coop_substrate

  @doc """
  Create the `records` schema and its tables if they are missing, before the
  store starts: an installation that predates them needs no manual step. A
  no-op once they exist.
  """
  @spec setup!() :: :ok
  def setup! do
    config = config()

    {:ok, conn} =
      config
      |> EventStore.Config.default_postgrex_opts()
      |> Keyword.put(:pool_size, 1)
      |> Postgrex.start_link()

    try do
      # One database transaction covers the existence check and all DDL.
      # The database lock serializes independent release/node startups too.
      {:ok, :ok} =
        Postgrex.transaction(
          conn,
          fn tx ->
            Postgrex.query!(tx, "SELECT pg_advisory_xact_lock(1936028785, 1903521652)", [])
            schema = Keyword.fetch!(config, :schema)

            %{rows: [[exists]]} =
              Postgrex.query!(
                tx,
                """
                SELECT EXISTS (SELECT 1 FROM information_schema.tables
                  WHERE table_schema = $1 AND table_name = 'events')
                """,
                [schema]
              )

            unless exists do
              quoted = String.replace(schema, "\"", "\"\"")
              Postgrex.query!(tx, ~s(CREATE SCHEMA IF NOT EXISTS "#{quoted}"), [])
              {:ok, _} = EventStore.Storage.Initializer.run!(tx, config)
            end

            :ok
          end,
          timeout: 60_000
        )

      :ok
    after
      GenServer.stop(conn)
    end
  end

  defmodule Serializer do
    @moduledoc "Erlang terms, read back with `:safe`: no atom is created from a stored record."

    @behaviour EventStore.Serializer

    @impl true
    def serialize(term), do: :erlang.term_to_binary(term)

    @impl true
    def deserialize(binary, _config), do: :erlang.binary_to_term(binary, [:safe])
  end
end
