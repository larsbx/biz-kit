defmodule Mix.Tasks.Harness.Adopt do
  @shortdoc "THE signature: --spec <hex> --defaults <hex> --model <hex> [--yes]"
  @moduledoc """
  Runbook phase 5 — the pipeline's one human signature (corpus 11 §1.4),
  governance-keyed, bound to the LATEST compiled model. Read the spec before
  you type `confirm`.
  """

  use Mix.Task

  alias CoopSubstrate.Harness.Ops
  alias CoopSubstrate.Harness.Ops.CLI

  @impl true
  def run(args) do
    CLI.start_app()

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [spec: :string, defaults: :string, model: :string, yes: :boolean]
      )

    [spec, defaults, model] =
      for key <- [:spec, :defaults, :model] do
        Base.decode16!(opts[key] || Mix.raise("missing --#{key}"), case: :mixed)
      end

    CLI.confirm!(
      "ADOPT the D spec — the one human signature of this pipeline.\n" <>
        "spec=#{opts[:spec]}\ndefaults=#{opts[:defaults]}\nmodel=#{opts[:model]}",
      opts
    )

    CLI.report(Ops.adopt(spec, defaults, model))
  end
end
