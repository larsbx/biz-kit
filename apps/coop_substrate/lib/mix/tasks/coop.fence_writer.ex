defmodule Mix.Tasks.Coop.FenceWriter do
  @shortdoc "Fence a retired writer: coop.fence_writer <WRITER> --chapter C --database-url URL [--reason R] [--yes]"
  @moduledoc """
  The retirement cutover fence (`CoopSubstrate.WriterFence`):

      mix coop.fence_writer eatsbot --chapter ch --database-url postgres://… --reason "R5 cutover"

  If the ledger holds no `LegacyWriterFenced` order for the writer in the
  chapter, shows the order and, once confirmed, signs it with the governance
  key in `HARNESS_KEYS_DIR` and appends it (`--reason` is then required).
  A writer whose history is kept needs its archive recorded first
  (`mix coop.archive_writer`) and requires `--archive DIR`,
  `--manifest-sha256 HEX`, and `--archive-event-id ID`. The complete archive
  and its exact canonical governance record are checked before loading a key,
  again after confirmation, and again before installation. No saved receipt
  substitutes for reopening the files. Until preflight passes nothing is signed.
  Then installs the fence on the writer's database, in one transaction, from
  the order on the ledger. Running it again re-applies the fence, covering
  tables created since. Starts the application, so the ledger is reachable.
  """

  use Mix.Task

  alias CoopSubstrate.Harness.Ops
  alias CoopSubstrate.{HistoryArchive, WriterFence}

  @usage "usage: mix coop.fence_writer <WRITER> --chapter C --database-url URL [--reason R] [--yes] " <>
           "[--archive DIR --manifest-sha256 HEX --archive-event-id ID]"

  @impl true
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          chapter: :string,
          database_url: :string,
          reason: :string,
          yes: :boolean,
          archive: :string,
          manifest_sha256: :string,
          archive_event_id: :string
        ]
      )

    with [] <- invalid,
         [writer] <- positional,
         true <- writer in WriterFence.writers(),
         chapter when is_binary(chapter) and chapter != "" <- opts[:chapter],
         {:ok, conn_opts} <- CoopSubstrate.DatabaseUrl.to_postgrex(opts[:database_url]) do
      require_archive_options!(writer, opts)
      Mix.Task.run("app.start")

      archive_opts =
        Keyword.put(opts, :expected_source, %{
          "hostname" => conn_opts[:hostname],
          "database" => conn_opts[:database]
        })

      preflight!(chapter, writer, archive_opts)
      :ok = ordered(chapter, writer, archive_opts)

      case WriterFence.install(chapter, writer, conn_opts, archive_opts) do
        {:ok, fenced} ->
          Mix.shell().info("fenced: #{writer}, #{fenced.tables} tables, order #{fenced.event_id}")

          if is_map(fenced.archive_verification),
            do: Mix.shell().info(Jason.encode!(fenced.archive_verification, pretty: true))

        {:error, reason} ->
          Mix.raise("not fenced: #{inspect(reason)}")
      end
    else
      _ -> Mix.raise(@usage)
    end
  end

  defp require_archive_options!(writer, opts) do
    if HistoryArchive.spec(writer) != nil and
         not Enum.all?([:archive, :manifest_sha256, :archive_event_id], fn key ->
           is_binary(opts[key]) and opts[key] != ""
         end) do
      Mix.raise(
        "archive verification required: --archive DIR --manifest-sha256 HEX --archive-event-id ID"
      )
    end
  end

  defp preflight!(chapter, writer, opts) do
    case HistoryArchive.preflight(chapter, writer, opts) do
      {:ok, evidence} ->
        evidence

      {:error, reason} ->
        Mix.raise("archive preflight refused; nothing signed: #{inspect(reason)}")
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

        # The archive may have changed while governance reviewed the prompt.
        preflight!(chapter, writer, opts)

        case WriterFence.declare(chapter, writer, reason, signer) do
          {:ok, _} -> :ok
          {:error, reason} -> Mix.raise("fence order refused: #{inspect(reason)}")
        end

      {:error, reason} ->
        Mix.raise("cannot read the ledger: #{inspect(reason)}")
    end
  end
end
