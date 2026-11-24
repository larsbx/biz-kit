defmodule CoopSubstrate.HistoryArchive.LedgerReader do
  @moduledoc false

  # A standalone preflight needs only EventStore's read client. Starting the
  # whole application would also initialize operational tables and repair log
  # indexes. This client requests read-only PostgreSQL sessions instead.
  def run(fun) when is_function(fun, 0) do
    with {:ok, _} <- Application.ensure_all_started(:eventstore),
         :ok <- CoopSubstrate.Procurement.register_types!() do
      config = Application.get_env(:coop_substrate, CoopSubstrate.EventStore, [])

      parameters =
        config
        |> Keyword.get(:parameters, [])
        |> Enum.reject(fn {key, _} -> to_string(key) == "default_transaction_read_only" end)

      case CoopSubstrate.EventStore.start_link(
             parameters: [default_transaction_read_only: "on"] ++ parameters,
             shared_connection_pool: nil
           ) do
        {:ok, reader} ->
          try do
            fun.()
          after
            Supervisor.stop(reader)
          end

        {:error, {:already_started, _}} ->
          # Calling from an already-running node still performs reads only;
          # do not stop or reconfigure that node's client.
          fun.()

        {:error, reason} ->
          {:error, {:ledger_reader_unavailable, reason}}
      end
    end
  end
end
