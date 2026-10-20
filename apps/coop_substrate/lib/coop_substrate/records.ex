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

    # The database is the ledger's, already there: only the schema, which
    # needs no right to create databases.
    case EventStore.Storage.Schema.create(config) do
      :ok -> :ok
      {:error, :already_up} -> :ok
      {:error, reason} -> raise "the records schema could not be created: #{reason}"
    end

    EventStore.Tasks.Init.exec(config, quiet: true)
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
