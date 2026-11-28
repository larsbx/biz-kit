defmodule CoopSubstrate.ReleaseTasks do
  @moduledoc """
  Release steps for the ledger, shared by every release that carries it
  (docs/deploy.md). Run explicitly by an operator, never on boot.
  """

  alias CoopSubstrate.{Log, RestaurantKeyAudit}
  alias CoopSubstrate.HistoryArchive.LedgerReader

  @event_stores [CoopSubstrate.EventStore, CoopSubstrate.Records]

  @doc """
  Create the ledger's event store database if it is missing and initialize
  both stores. Idempotent: an existing database or schema is left as is. Only
  Postgrex starts; no application does.
  """
  @spec init_event_stores() :: :ok
  def init_event_stores do
    Application.load(:coop_substrate)
    {:ok, _} = Application.ensure_all_started(:postgrex)

    for store <- @event_stores do
      config = EventStore.Config.parsed(store, :coop_substrate)
      # Each raises on failure.
      EventStore.Tasks.Create.exec(config, quiet: true)
      EventStore.Tasks.Init.exec(config, quiet: true)
    end

    :ok
  end

  @doc """
  Audit the ledger's chapter key history (`CoopSubstrate.RestaurantKeyAudit`)
  at its stored head, read-only and without the appender: only EventStore's
  read client starts, in read-only sessions, and a running node's client is
  reused instead (docs/architecture/restaurant-key-collision-audit.md).

  Prints the report as JSON and returns `{:ok, report}` when no finding is
  open. Otherwise it raises after printing, and it raises when the prefix
  does not verify. It never halts, so under `rpc` a raise ends only the
  calling VM.

  Options: `as_of: "SEQ:HEX"`, a report's `as_of` or a head captured from the
  appender, audits exactly that prefix; `puts:` replaces `IO.puts/1`.
  """
  @spec audit_keys(keyword()) :: {:ok, map()}
  def audit_keys(opts \\ []) do
    Application.load(:coop_substrate)
    puts = Keyword.get(opts, :puts, &IO.puts/1)

    read = fn ->
      with {:ok, head} <- ledger_head(opts[:as_of]), do: RestaurantKeyAudit.scan(head)
    end

    case LedgerReader.run(read) do
      {:ok, %{open_count: open} = report} ->
        puts.(Jason.encode!(report, pretty: true))

        if open > 0,
          do: raise("key audit: #{open} open finding(s) of #{report.violation_count}")

        {:ok, report}

      {:error, reason} ->
        raise "key audit refused: #{inspect(reason)}"
    end
  end

  defp ledger_head(nil), do: Log.stored_head()

  defp ledger_head(as_of) when is_binary(as_of) do
    with [seq, hex] <- String.split(as_of, ":"),
         {seq, ""} <- Integer.parse(seq),
         {:ok, hash} <- Base.decode16(hex, case: :mixed) do
      {:ok, %{global_seq: seq, global_hash: if(hash != "", do: hash)}}
    else
      _ -> {:error, :invalid_ledger_head}
    end
  end

  defp ledger_head(_as_of), do: {:error, :invalid_ledger_head}
end
