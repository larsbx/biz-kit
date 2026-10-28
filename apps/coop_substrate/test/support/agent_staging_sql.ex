defmodule CoopSubstrate.AgentStagingSQL do
  @moduledoc false
  @behaviour Postgrex.SimpleConnection
  def init(_), do: {:ok, nil}
  def notify(_, _, _), do: :ok
  def handle_call({:sql, sql}, from, _), do: {:query, sql, from}

  def handle_result(result, from) do
    Postgrex.SimpleConnection.reply(from, result)
    {:noreply, nil}
  end

  def setup! do
    config = Application.fetch_env!(:coop_substrate, CoopSubstrate.EventStore)
    # This helper is destructive and must only run against the disposable test database.
    "coop_substrate_eventstore_test" = config[:database]
    {:ok, conn} = Postgrex.SimpleConnection.start_link(__MODULE__, [], config)

    try do
      for file <- Path.wildcard(Path.expand("../../../../deploy/agent-core/sql/00*.sql", __DIR__)) do
        case Postgrex.SimpleConnection.call(conn, {:sql, File.read!(file)}, 30_000) do
          results when is_list(results) -> :ok
          error -> raise "agent staging migration failed: #{inspect(error)}"
        end
      end

      results =
        Postgrex.SimpleConnection.call(
          conn,
          {:sql, "TRUNCATE agent_ops.execution_attempts CASCADE"}
        )

      true = is_list(results)
    after
      GenServer.stop(conn)
    end
  end
end
