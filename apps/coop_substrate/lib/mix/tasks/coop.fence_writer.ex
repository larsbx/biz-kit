defmodule Mix.Tasks.Coop.FenceWriter do
  @shortdoc "Fence a retired writer: coop.fence_writer <WRITER> --chapter C --database-url URL [--reason R] [--yes]"
  @moduledoc """
  The retirement cutover fence (`CoopSubstrate.WriterFence`):

      mix coop.fence_writer eatsbot --chapter ch --database-url postgres://… --reason "R5 cutover"

  If the ledger holds no `LegacyWriterFenced` order for the writer in the
  chapter, shows the order and, once confirmed, signs it with the governance
  key in `HARNESS_KEYS_DIR` and appends it (`--reason` is then required).
  A writer whose history is kept needs its archive recorded first
  (`mix coop.archive_writer`); until then nothing is signed.
  Then installs the fence on the writer's database, in one transaction, from
  the order on the ledger. Running it again re-applies the fence, covering
  tables created since. Starts the application, so the ledger is reachable.
  """

  use Mix.Task

  alias CoopSubstrate.Harness.Ops
  alias CoopSubstrate.{HistoryArchive, WriterFence}

  @usage "usage: mix coop.fence_writer <WRITER> --chapter C --database-url URL [--reason R] [--yes]"

  @impl true
  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [chapter: :string, database_url: :string, reason: :string, yes: :boolean]
      )

    with [writer] <- positional,
         chapter when is_binary(chapter) <- opts[:chapter],
         {:ok, conn_opts} <- CoopSubstrate.DatabaseUrl.to_postgrex(opts[:database_url]) do
      Mix.Task.run("app.start")

      with {:error, :history_not_archived} <- HistoryArchive.ready_to_fence(chapter, writer),
           do: Mix.raise("record #{writer}'s history first: mix coop.archive_writer #{writer} …")

      :ok = ordered(chapter, writer, opts)

      case WriterFence.install(chapter, writer, conn_opts) do
        {:ok, fenced} ->
          Mix.shell().info("fenced: #{writer}, #{fenced.tables} tables, order #{fenced.event_id}")

        {:error, reason} ->
          Mix.raise("not fenced: #{inspect(reason)}")
      end
    else
      _ -> Mix.raise(@usage)
    end
  end

  defp ordered(chapter, writer, opts) do
    case WriterFence.order(chapter, writer) do
      {:ok, _} ->
        :ok

      {:error, :not_ordered} ->
        reason = opts[:reason] || Mix.raise("no fence order on the ledger; --reason is required")
        {:ok, signer} = Ops.load_signer("governance")

        Mix.shell().info("""
        Order the fence of #{writer} in chapter #{chapter}, signed by governance key #{signer.key_id}:
          reason  #{reason}
        Every later write to its database is refused. Nothing on the ledger unfences it.
        """)

        unless opts[:yes] || Mix.shell().yes?("Sign and append?"),
          do: Mix.raise("not fenced; nothing was signed")

        case WriterFence.declare(chapter, writer, reason, signer) do
          {:ok, _} -> :ok
          {:error, reason} -> Mix.raise("fence order refused: #{inspect(reason)}")
        end

      {:error, reason} ->
        Mix.raise("cannot read the ledger: #{inspect(reason)}")
    end
  end
end
