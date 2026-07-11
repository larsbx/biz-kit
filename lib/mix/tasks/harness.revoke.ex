defmodule Mix.Tasks.Harness.Revoke do
  @shortdoc "Revoke consent: --ref IV-1 [--seed-file path]  (seed prompted if no file)"
  @moduledoc """
  Runbook phase 2 — revocation is the interviewee's signature, made with the
  seed they hold. Never pass the seed as a shell argument (history leakage):
  use `--seed-file` or the prompt. Revocation is terminal and atomically
  excluding — it can flip gate(D); that is correct behavior.
  """

  use Mix.Task

  alias CoopSubstrate.Harness.Ops
  alias CoopSubstrate.Harness.Ops.CLI

  @impl true
  def run(args) do
    CLI.start_app()

    {opts, _, _} = OptionParser.parse(args, strict: [ref: :string, seed_file: :string])
    ref = opts[:ref] || Mix.raise("missing --ref")

    seed_hex =
      case opts[:seed_file] do
        nil -> Mix.shell().prompt("Interviewee seed (hex): ") || ""
        path -> File.read!(path)
      end

    CLI.report(Ops.revoke_consent(ref, seed_hex))
  end
end
