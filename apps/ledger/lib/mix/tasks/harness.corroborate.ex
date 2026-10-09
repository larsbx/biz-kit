defmodule Mix.Tasks.Harness.Corroborate do
  @shortdoc "Corroborate a claim: <claim_ref> <finding_id> <finding_id> ..."
  @moduledoc "Runbook phase 4 — the gate requires k DISTINCT interviewees behind the findings."

  use Mix.Task

  alias CoopSubstrate.Harness.Ops
  alias CoopSubstrate.Harness.Ops.CLI

  @impl true
  def run([claim_ref | finding_refs]) when finding_refs != [] do
    CLI.start_app()
    CLI.report(Ops.corroborate(claim_ref, finding_refs))
  end

  def run(_), do: Mix.raise("usage: mix harness.corroborate <claim_ref> <finding_id>...")
end
