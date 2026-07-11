defmodule Mix.Tasks.Cockpit do
  @shortdoc "One screen of derived truth: queue + guard board + B_op + fold health"
  @moduledoc "Corpus 10 §5. Absent numbers say so (ε denominator, checkpoint age, veto feed)."

  use Mix.Task

  alias CoopSubstrate.Cockpit
  alias CoopSubstrate.Harness.Ops.CLI

  @impl true
  def run(_args) do
    CLI.start_app()

    case Cockpit.boards("chapter-genesis", System.system_time(:millisecond)) do
      {:ok, boards} ->
        CLI.ok("queue: open=#{boards.queue.open} nearest_deadline=#{inspect(boards.queue.nearest_deadline_ms)}")

        Enum.each(boards.processes, fn p ->
          CLI.ok(
            "process=#{p.process} raised=#{p.raised} open=#{p.open} " <>
              "approved=#{p.approved} declined=#{p.declined} defects=#{p.defects} " <>
              "approval_rate=#{inspect(p.approval_rate)} heat=#{inspect(p.act_heat)} " <>
              "(epsilon: awaits domain act streams)"
          )
        end)

        case boards.b_op do
          %{configured: false} ->
            CLI.ok("b_op: unconfigured — declare cockpit/{b_op,period_ms,cost_default}")

          b ->
            CLI.ok(
              "b_op: period=#{b.period_ref} spent=#{b.spent_minutes}min " <>
                "budget=#{b.budget_minutes}min breach=#{b.breach}"
            )
        end

        health = boards.fold_health
        CLI.ok("fold_health: head_seq=#{health.head_seq} head_age_ms=#{health[:head_age_ms] || "n/a"}")
        CLI.ok("veto_feed: (no veto-eligible acts exist — seam)")

      {:error, reason} ->
        CLI.reject(reason)
    end
  end
end
