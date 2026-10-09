defmodule Mix.Tasks.Cockpit.Decide do
  @shortdoc "Resolve an R item: <item_id> approved|declined|returned_defect [--reason ...] [--yes]"
  @moduledoc """
  Corpus 10 §5 — a lax-direction signature. Approval authorizes the acting
  domain; it executes nothing here. `returned_defect` is terminal for the
  item id: the emitter must raise a fresh, complete item.
  """

  use Mix.Task

  alias CoopSubstrate.Harness.Ops
  alias CoopSubstrate.Harness.Ops.CLI

  @impl true
  def run(args) do
    CLI.start_app()

    {opts, positional, _} = OptionParser.parse(args, strict: [reason: :string, yes: :boolean])

    case positional do
      [item_id, verdict] ->
        CLI.confirm!("Resolve #{item_id} as #{verdict}.", opts)
        CLI.report(Ops.decide(item_id, verdict, opts[:reason]))

      _ ->
        Mix.raise("usage: mix cockpit.decide <item_id> <verdict> [--reason ...] [--yes]")
    end
  end
end
