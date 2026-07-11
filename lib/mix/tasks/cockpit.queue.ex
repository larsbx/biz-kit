defmodule Mix.Tasks.Cockpit.Queue do
  @shortdoc "The R-queue: open items, deadline-ordered"
  @moduledoc "Corpus 10 §5 — judge and sign; the packet refs are on each line."

  use Mix.Task

  alias CoopSubstrate.Cockpit
  alias CoopSubstrate.Harness.Ops.CLI

  @impl true
  def run(_args) do
    CLI.start_app()

    case Cockpit.queue("chapter-genesis") do
      {:ok, []} ->
        CLI.ok("queue empty")

      {:ok, items} ->
        Enum.each(items, fn item ->
          CLI.ok(
            "item=#{item.item_id} deadline_ms=#{item.deadline_ms} process=#{item.process} " <>
              "act=#{item.act_type} rec=#{item.recommendation}"
          )
        end)

      {:error, reason} ->
        CLI.reject(reason)
    end
  end
end
