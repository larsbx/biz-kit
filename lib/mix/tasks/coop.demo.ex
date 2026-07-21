defmodule Mix.Tasks.Coop.Demo do
  @shortdoc "Run the simulated end-to-end demo (sim chapters only)"

  @moduledoc """
  Runs `CoopSubstrate.Sim.Demo.run/1` — the whole simulated cycle on a
  fresh `chapter-sim-demo-*` chapter — and prints the returned result.
  Pure printer: every number comes from the returned map.

      mix coop.demo
      mix coop.demo --chapter chapter-sim-my-run

  Non-sim chapter ids are refused (the boundary is structural; see
  docs/phase11a_plan.md). Nothing printed here is field evidence.
  """

  use Mix.Task

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [chapter: :string])
    Mix.Task.run("app.start")

    case CoopSubstrate.Sim.Demo.run(opts[:chapter]) do
      {:error, :not_a_sim_chapter} ->
        Mix.raise("refused: the demo runs only on chapter-sim* chapters")

      {:ok, result} ->
        print(result)
    end
  end

  defp print(r) do
    section("Simulated gate(D) — the real pipeline on synthetic data")
    row("chapter", r.chapter_id)
    row("gate(D)", r.gate)
    row("BuildStarted at global_seq", r.build_seq)

    section("Tender routing (envelope: detroit->chicago, dry_van, floor $1500.00)")
    Enum.each(Enum.sort(r.routing), fn {id, decision} -> row(id, decision) end)
    row("R queue before consumption", r.r_queue.before_consumption)
    row("R queue after approval consumed (9B)", r.r_queue.after_consumption)

    section("The load: tracked, dwelled, invoiced")
    row("dwell", r.dwell)
    row("invoice (gate-recomputed)", r.invoice)

    section("Demo kit + guards (8D — folds over the whole exhaust)")
    row("demo_kit", r.demo_kit)
    row("guards", r.guards)

    section("Obligation rail (9A — netting + ring aggregates)")
    row("netting before", r.netting.report_before)
    row("rings before", r.netting.rings_before)
    row("netting after executed round", r.netting.report_after)
    row("rings after", r.netting.rings_after)

    section("Portability + honesty")
    row("departure bundle streams", r.bundle_streams)
    row("bundle offline verification", r.verifications.bundle_offline)
    row("chain audit", r.verifications.chains)
  end

  defp section(title) do
    Mix.shell().info("\n" <> String.duplicate("=", 64))
    Mix.shell().info("  " <> title)
    Mix.shell().info(String.duplicate("=", 64))
  end

  defp row(label, value) do
    Mix.shell().info("#{label}: #{inspect(value, pretty: true, width: 60)}")
  end
end
