defmodule Mix.Tasks.Harness.Interview do
  @shortdoc "Record an interview: --id I-1 --interviewee IV-1 [--section D] [--mode call]"
  @moduledoc "Runbook phase 3. Modes: call | chat | form (no automated voice)."

  use Mix.Task

  alias CoopSubstrate.Harness.Ops
  alias CoopSubstrate.Harness.Ops.CLI

  @impl true
  def run(args) do
    CLI.start_app()

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [id: :string, interviewee: :string, section: :string, mode: :string]
      )

    CLI.report(
      Ops.record_interview(
        opts[:id] || Mix.raise("missing --id"),
        opts[:interviewee] || Mix.raise("missing --interviewee"),
        opts[:section] || "D",
        opts[:mode] || "call"
      )
    )
  end
end
