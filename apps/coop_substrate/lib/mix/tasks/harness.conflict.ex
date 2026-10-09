defmodule Mix.Tasks.Harness.Conflict do
  @shortdoc "Flag a conflict: <claim_ref> <finding_id> <finding_id> ..."
  @moduledoc "Runbook phase 4 — disagreements are model content; never pick a winner silently."

  use Mix.Task

  alias CoopSubstrate.Harness.Ops
  alias CoopSubstrate.Harness.Ops.CLI

  @impl true
  def run([claim_ref | finding_refs]) when finding_refs != [] do
    CLI.start_app()
    CLI.report(Ops.conflict(claim_ref, finding_refs))
  end

  def run(_), do: Mix.raise("usage: mix harness.conflict <claim_ref> <finding_id>...")
end
