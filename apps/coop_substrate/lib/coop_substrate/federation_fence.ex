defmodule CoopSubstrate.FederationFence do
  @moduledoc false
  # Called only inside Log. Lock the SAME stream row updated by EventStore
  # append_to_stream, including other appenders. Never trust a stale gate just
  # because a cluster singleton still appears registered during a partition.
  def run(context, head, gate, request, effect) do
    schema = context.schema

    if is_binary(schema) and Regex.match?(~r/\A[a-z_][a-z0-9_]*\z/, schema) do
      case Postgrex.transaction(
             context.connection,
             fn conn ->
               with {:ok, %{rows: [[stream, version]]}} <-
                      Postgrex.query(
                        conn,
                        "SELECT stream_id, stream_version FROM #{schema}.streams WHERE stream_uuid = 'ledger' FOR UPDATE NOWAIT",
                        []
                      ),
                    true <- version == head.global_seq,
                    {:ok, %{rows: [[bytes]]}} <-
                      Postgrex.query(
                        conn,
                        "SELECT e.data FROM #{schema}.events e JOIN #{schema}.stream_events se ON se.event_id = e.event_id WHERE se.stream_id = $1 AND se.stream_version = $2",
                        [stream, version]
                      ),
                    true <- :crypto.hash(:sha256, bytes) == head.global_hash,
                    :ok <-
                      CoopSubstrate.FederationAuthority.authorize(
                        gate,
                        context,
                        request,
                        System.system_time(:second)
                      ) do
                 effect.()
               else
                 _ -> Postgrex.rollback(conn, :unverified_local_authority)
               end
             end,
             timeout: :infinity
           ) do
        {:ok, result} -> {:ok, result}
        _ -> {:error, :unverified_local_authority}
      end
    else
      {:error, :unverified_local_authority}
    end
  rescue
    _ -> {:error, :unverified_local_authority}
  catch
    _, _ -> {:error, :unverified_local_authority}
  end
end
