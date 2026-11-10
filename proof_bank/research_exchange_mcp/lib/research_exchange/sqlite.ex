defmodule ResearchExchange.SQLite do
  @moduledoc false

  @script Path.expand("../../bin/sqlite_journal.py", __DIR__)
  @timeout 7_000
  @domain "research-exchange/sqlite-journal/v1\n"
  @fields [:submissions, :jobs, :replay, :revoked]

  def open(path, key) do
    port =
      Port.open({:spawn_executable, System.find_executable("python3")}, [
        :binary,
        :exit_status,
        {:packet, 4},
        {:args, ["-I", @script, path]},
        {:env, [{~c"RESEARCH_EXCHANGE_TOKEN", false}, {~c"RESEARCH_EXCHANGE_CONFIG", false}]}
      ])

    with {:ok, <<?O, epoch::64, version::64, snapshot::binary>>} <- exchange(port, "B"),
         {:ok, data} <- decode(snapshot, version, key) do
      {:ok, port, epoch, version, data}
    else
      _ -> {:error, :journal_unavailable}
    end
  end

  def fence(%{journal: port, epoch: epoch, version: version}),
    do: result(exchange(port, <<?R, epoch::64, version::64>>))

  def commit(%{journal: port, epoch: epoch, version: version}, updated) do
    payload = :erlang.term_to_binary(Map.take(updated, @fields))
    mac = mac(updated.config.receipt_key, version + 1, payload)
    result(exchange(port, <<?W, epoch::64, version::64, mac::binary, payload::binary>>))
  end

  defp decode("", 0, _key), do: {:ok, %{}}

  defp decode(<<signature::binary-32, payload::binary>>, version, key) do
    if :crypto.hash_equals(signature, mac(key, version, payload)),
      do: {:ok, :erlang.binary_to_term(payload, [:safe])},
      else: {:error, :journal_identity_mismatch}
  end

  defp decode(_, _, _), do: {:error, :journal_identity_mismatch}

  defp mac(key, version, payload),
    do: :crypto.mac(:hmac, :sha256, key, [@domain, <<version::64>>, payload])

  defp result({:ok, "O"}), do: :ok
  defp result({:ok, "F"}), do: {:error, :journal_fenced}
  defp result(_), do: {:error, :journal_unavailable}

  defp exchange(port, bytes) do
    Port.command(port, bytes)

    receive do
      {^port, {:data, reply}} -> {:ok, reply}
      {^port, {:exit_status, _}} -> {:error, :journal_unavailable}
    after
      @timeout ->
        Port.close(port)
        {:error, :journal_unavailable}
    end
  catch
    :error, :badarg -> {:error, :journal_unavailable}
  end
end
