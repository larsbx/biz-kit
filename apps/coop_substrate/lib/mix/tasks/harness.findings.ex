defmodule Mix.Tasks.Harness.Findings do
  @shortdoc "Record findings: <batch.json> | --id F-1 --interview I-1 --kind pain --body '...'"
  @moduledoc """
  Runbook phase 3 — enter findings the same day, one per fact, quoting them.
  Batch file: a JSON list of {finding_id, interview_ref, kind, body}. A
  rejection stops the batch at that entry; prior findings stand (each is its
  own signed event).
  """

  use Mix.Task

  alias CoopSubstrate.Harness.Ops
  alias CoopSubstrate.Harness.Ops.CLI

  @impl true
  def run(args) do
    CLI.start_app()

    case args do
      [path] ->
        entries = path |> File.read!() |> Jason.decode!()

        case Ops.record_findings(entries) do
          {:ok, count} -> CLI.ok("appended #{count} findings")
          {:error, {finding_id, reason, appended: count}} ->
            CLI.ok("appended #{count} findings before the rejection")
            CLI.reject({finding_id, reason})
        end

      _ ->
        {opts, _, _} =
          OptionParser.parse(args,
            strict: [id: :string, interview: :string, kind: :string, body: :string]
          )

        CLI.report(
          Ops.record_finding(
            opts[:id] || Mix.raise("missing --id or a batch file"),
            opts[:interview] || Mix.raise("missing --interview"),
            opts[:kind] || Mix.raise("missing --kind"),
            opts[:body] || Mix.raise("missing --body")
          )
        )
    end
  end
end
