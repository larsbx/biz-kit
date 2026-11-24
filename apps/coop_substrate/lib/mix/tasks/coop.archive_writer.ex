defmodule Mix.Tasks.Coop.ArchiveWriter do
  @shortdoc "Archive a retired writer's history: coop.archive_writer <WRITER> --database-url URL --out DIR"
  @moduledoc """
  A retired writer's history as inert audit data (`CoopSubstrate.HistoryArchive`):

      mix coop.archive_writer spruce_goose --database-url postgres://… --out DIR \\
        [--file PATH]… [--allow-undispatched-outbox] [--chapter C] [--yes]

  Exports the writer's tables from one snapshot into the new directory `DIR`,
  with the files its records reference: the writer's own defaults plus each
  `--file` (the deployment's Systemwide SOP, for one). With `--chapter`, then
  shows the manifest digest and, once confirmed, signs `LegacyHistoryArchived`
  with the governance key in `HARNESS_KEYS_DIR` and appends it; the writer's
  fence needs that record.

      mix coop.archive_writer --verify DIR [--chapter C]

  Re-hashes an archive against its manifest and, with `--chapter`, checks that
  the ledger records its digest. This generic check permits absent tables;
  cutover additionally requires `mix coop.preflight_writer` with the selected
  archive event ID and manifest digest. Retain that receipt outside the archive.
  """

  use Mix.Task

  alias CoopSubstrate.{DatabaseUrl, HistoryArchive}
  alias CoopSubstrate.Harness.Ops

  @usage "usage: mix coop.archive_writer <WRITER> --database-url URL --out DIR [--file PATH]… " <>
           "[--allow-undispatched-outbox] [--chapter C] [--yes] | --verify DIR [--chapter C]"
  @root Path.expand("../../../../..", __DIR__)

  @impl true
  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [
          database_url: :string,
          out: :string,
          file: :keep,
          allow_undispatched_outbox: :boolean,
          chapter: :string,
          verify: :string,
          yes: :boolean
        ]
      )

    case {positional, opts[:verify]} do
      {[], dir} when is_binary(dir) -> verify(dir, opts[:chapter])
      {[writer], nil} -> export(writer, opts)
      _ -> Mix.raise(@usage)
    end
  end

  defp export(writer, opts) do
    spec = HistoryArchive.spec(writer) || Mix.raise("#{writer} keeps no history to archive")

    with {:ok, conn_opts} <- DatabaseUrl.to_postgrex(opts[:database_url]),
         out when is_binary(out) <- opts[:out] do
      files = Enum.map(spec.files, &Path.join(@root, &1)) ++ Keyword.get_values(opts, :file)

      case HistoryArchive.export(writer, conn_opts, out,
             files: files,
             allow_undispatched_outbox: opts[:allow_undispatched_outbox] || false
           ) do
        {:ok, %{manifest_sha256: digest, tables: n}} ->
          Mix.shell().info(
            "archived: #{writer}, #{n} tables into #{out}, manifest sha256 #{digest}"
          )

          if chapter = opts[:chapter], do: record(chapter, writer, digest, opts)

        {:error, {:duplicate_file_name, name}} ->
          Mix.raise("two files are named #{name}; an archive keeps each under its base name")

        {:error, {:undispatched_outbox, n}} ->
          Mix.raise(
            "#{n} outbox rows are undispatched: drain them, or keep them in the archive " <>
              "with --allow-undispatched-outbox"
          )

        {:error, reason} ->
          Mix.raise("not archived: #{inspect(reason)}")
      end
    else
      _ -> Mix.raise(@usage)
    end
  end

  defp record(chapter, writer, digest, opts) do
    Mix.Task.run("app.start")
    {:ok, signer} = Ops.load_signer("governance")

    Mix.shell().info("""
    Record the history archive of #{writer} in chapter #{chapter}, signed by governance key #{signer.key_id}:
      manifest sha256  #{digest}
    Run coop.preflight_writer before ordering or installing its fence.
    The record grants no authority and does not certify file completeness.
    """)

    unless opts[:yes] || Mix.shell().yes?("Sign and append?"),
      do: Mix.raise("archived but not recorded; nothing was signed")

    case HistoryArchive.declare(chapter, writer, digest, signer) do
      {:ok, _} -> Mix.shell().info("recorded: #{writer} #{digest}")
      {:error, reason} -> Mix.raise("archive record refused: #{inspect(reason)}")
    end
  end

  defp verify(dir, chapter) do
    case HistoryArchive.verify(dir) do
      {:ok, %{manifest_sha256: digest, writer: writer}} ->
        Mix.shell().info("intact: #{writer}, manifest sha256 #{digest}")
        if chapter, do: recorded!(chapter, writer, digest)

      {:error, {:mismatch, paths}} ->
        Mix.raise("archive does not match its manifest: #{Enum.join(paths, ", ")}")
    end
  end

  defp recorded!(chapter, writer, digest) do
    Mix.Task.run("app.start")

    case HistoryArchive.recorded(chapter, writer) do
      {:ok, envs} ->
        if Enum.any?(envs, &(&1.payload["manifest_sha256"] == digest)),
          do: Mix.shell().info("recorded on the ledger in #{chapter}"),
          else: Mix.raise("the ledger records other archives of #{writer}, not this one")

      {:error, reason} ->
        Mix.raise("not recorded on the ledger: #{inspect(reason)}")
    end
  end
end
