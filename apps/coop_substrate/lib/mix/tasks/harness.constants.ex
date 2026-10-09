defmodule Mix.Tasks.Harness.Constants do
  @shortdoc "Declare the gate constants: --n --c --d --k [--section D] [--yes]"
  @moduledoc """
  Runbook 0.3 — declared before the first gate evaluation, retro-fit void
  (00 Art. IV.2). A later declaration may revise values forward, visibly.
  """

  use Mix.Task

  alias CoopSubstrate.Harness.Ops
  alias CoopSubstrate.Harness.Ops.CLI

  @impl true
  def run(args) do
    CLI.start_app()

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [n: :integer, c: :integer, d: :integer, k: :integer, section: :string, yes: :boolean]
      )

    section = opts[:section] || "D"

    for key <- [:n, :c, :d, :k], opts[key] == nil do
      Mix.raise("missing --#{key} (see docs/runbook_gate_d.md phase 0.3)")
    end

    CLI.confirm!(
      "Declare gate constants for section #{section}: " <>
        "n=#{opts[:n]} c=#{opts[:c]} d=#{opts[:d]} k=#{opts[:k]}",
      opts
    )

    case Ops.declare_constants(section, opts[:n], opts[:c], opts[:d], opts[:k]) do
      {:ok, names} -> Enum.each(names, &CLI.ok("declared #{&1}"))
      {:error, {name, {:error, reason}}} -> CLI.reject({name, reason})
      {:error, reason} -> CLI.reject(reason)
    end
  end
end
