defmodule Mix.Tasks.Harness.Honorarium do
  @shortdoc "Accrue an honorarium: --interviewee IV-1 --amount 5000"
  @moduledoc "Runbook 0.1 — accrual only; payout stays behind the [LEGAL] gate."

  use Mix.Task

  alias CoopSubstrate.Harness.Ops
  alias CoopSubstrate.Harness.Ops.CLI

  @impl true
  def run(args) do
    CLI.start_app()

    {opts, _, _} =
      OptionParser.parse(args, strict: [interviewee: :string, amount: :integer])

    CLI.report(
      Ops.honorarium(
        opts[:interviewee] || Mix.raise("missing --interviewee"),
        opts[:amount] || Mix.raise("missing --amount")
      )
    )
  end
end
