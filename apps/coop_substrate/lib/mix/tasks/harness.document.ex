defmodule Mix.Tasks.Harness.Document do
  @shortdoc "Collect a document: --interview I-1 --kind rate_confirmation <path>"
  @moduledoc "Runbook phase 3. `--kind recording` requires the interviewee's recording consent."

  use Mix.Task

  alias CoopSubstrate.Harness.Ops
  alias CoopSubstrate.Harness.Ops.CLI

  @impl true
  def run(args) do
    CLI.start_app()

    {opts, positional, _} =
      OptionParser.parse(args, strict: [interview: :string, kind: :string])

    path = List.first(positional) || Mix.raise("missing document path")

    case Ops.collect_document(
           opts[:interview] || Mix.raise("missing --interview"),
           opts[:kind] || Mix.raise("missing --kind"),
           File.read!(path)
         ) do
      {:ok, %{document_id: id, artifact_hash: hash}} ->
        CLI.ok("document=#{id} artifact=#{Base.encode16(hash, case: :lower)}")

      {:error, reason} ->
        CLI.reject(reason)
    end
  end
end
