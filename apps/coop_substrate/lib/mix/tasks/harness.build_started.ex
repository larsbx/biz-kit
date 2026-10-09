defmodule Mix.Tasks.Harness.BuildStarted do
  @shortdoc "The gate's marker: [--section D] — unrepresentable until gate(section) is true"
  @moduledoc "Runbook phase 7. A rejection here names the short leg; see mix harness.status."

  use Mix.Task

  alias CoopSubstrate.Harness.Ops
  alias CoopSubstrate.Harness.Ops.CLI

  @impl true
  def run(args) do
    CLI.start_app()
    {opts, _, _} = OptionParser.parse(args, strict: [section: :string])
    CLI.report(Ops.build_started(opts[:section] || "D"))
  end
end
