defmodule Mix.Tasks.Harness.Prospect do
  @shortdoc "Emit a funnel prospect: --ref P-1 --interviewee IV-1 --interview I-1 [--track D]"
  @moduledoc "Runbook phase 6 — requires the interviewee's prospect_record consent, active."

  use Mix.Task

  alias CoopSubstrate.Harness.Ops
  alias CoopSubstrate.Harness.Ops.CLI

  @impl true
  def run(args) do
    CLI.start_app()

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [ref: :string, interviewee: :string, interview: :string, track: :string]
      )

    CLI.report(
      Ops.prospect(
        opts[:ref] || Mix.raise("missing --ref"),
        opts[:interviewee] || Mix.raise("missing --interviewee"),
        opts[:interview] || Mix.raise("missing --interview"),
        opts[:track] || "D"
      )
    )
  end
end
