defmodule Mix.Tasks.Coop.PreflightWriter do
  @shortdoc "Verify a complete legacy archive against its exact governance record, without signing"
  @moduledoc """
  Read-only archive-to-fence acceptance, returning a JSON evidence receipt:

      mix coop.preflight_writer spruce_goose --chapter C --archive DIR \\
        --manifest-sha256 HEX --archive-event-id ID [--database-url URL]

  Re-opens the archive, checks all seven retained tables, COPY framing and
  outbox preservation, provenance, and the exact admitted archive record in a
  cryptographically verified canonical ledger prefix. If a fence already
  exists, the selected archive must precede the first order. The optional URL
  compares hostname/database labels only; it never connects to that database.

  This task starts only an EventStore read client, with read-only PostgreSQL
  sessions, and never loads a signing key or starts the application/appender.
  Keep its output outside the archive and retain it with custody and cutover
  evidence. Success is not cutover authorization or a source-quiescence proof.
  """
  use Mix.Task

  alias CoopSubstrate.{DatabaseUrl, HistoryArchive}

  @usage "usage: mix coop.preflight_writer spruce_goose --chapter C --archive DIR " <>
           "--manifest-sha256 HEX --archive-event-id ID [--database-url URL]"

  @impl true
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          chapter: :string,
          archive: :string,
          manifest_sha256: :string,
          archive_event_id: :string,
          database_url: :string
        ]
      )

    with [] <- invalid,
         [writer] <- positional,
         true <- HistoryArchive.spec(writer) != nil,
         chapter when is_binary(chapter) and chapter != "" <- opts[:chapter],
         true <-
           Enum.all?([:archive, :manifest_sha256, :archive_event_id], fn key ->
             is_binary(opts[key]) and opts[key] != ""
           end),
         {:ok, source} <- source(opts[:database_url]) do
      Mix.Task.run("app.config")

      # The wrapper verifies the files before starting this temporary reader.
      result =
        HistoryArchive.preflight(
          chapter,
          writer,
          opts |> Keyword.put(:expected_source, source) |> Keyword.put(:start_reader, true)
        )

      case result do
        {:ok, evidence} -> Mix.shell().info(Jason.encode!(evidence, pretty: true))
        {:error, reason} -> Mix.raise("preflight refused: #{inspect(reason)}")
      end
    else
      _ -> Mix.raise(@usage)
    end
  end

  defp source(nil), do: {:ok, nil}

  defp source(url) do
    with {:ok, opts} <- DatabaseUrl.to_postgrex(url),
         do: {:ok, %{"hostname" => opts[:hostname], "database" => opts[:database]}}
  end
end
