defmodule CoopSubstrate.SimDemoTest do
  @moduledoc """
  Phase 11A (docs/phase11a_plan.md): one call runs the whole simulated
  cycle and returns every number and verification verdict; the sim
  boundary is structural (non-sim chapters refused before anything is
  appended); runs are repeatable and deterministic.
  """

  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.Log
  alias CoopSubstrate.Sim.Demo

  # The scenario-invariant slice of a run (everything but the chapter id
  # and chapter-derived stream names).
  defp invariant(result), do: Map.drop(result, [:chapter_id, :build_seq, :bundle_streams])

  test "one call runs the whole cycle and verifies itself" do
    assert {:ok, r} = Demo.run("chapter-sim-acceptance")

    assert r.gate == {:ok, true}
    assert {:accept, 1, _} = r.routing["T-1"]
    assert {:decline, 1, _} = r.routing["T-2"]
    assert {:escalate, {:out_of_envelope, :lane}} = r.routing["T-3"]
    assert r.r_queue == %{before_consumption: ["tender/T-3"], after_consumption: []}

    assert r.dwell["pickup"].dwell_minutes == 200
    assert r.invoice.amount_minor == 218_000

    assert r.demo_kit == %{
             tenders: %{received: 3, accepted: 2, declined: 1, undecided: 0},
             loads: %{dispatched: 1, completed: 1},
             open_book: %{invoiced_minor: 218_000, credited_minor: 3_000, net_minor: 215_000},
             detention: %{minutes: 80, invoiced_minor: 8_000},
             check_calls: %{statuses_ingested: 3, minutes_returned: 45}
           }

    assert r.guards == %{"tender_accept" => %{decisions: 3, escalations: 1, epsilon_bp: 2_500}}

    assert r.netting.rings_before == %{"USD" => %{rings: 1, gross_minor: 280_000}}
    assert r.netting.rings_after == %{"USD" => %{rings: 1, gross_minor: 160_000}}
    assert [%{setoff: 60_000, net: {"M-ada", "M-bob", 40_000}}] = r.netting.report_before

    assert length(r.bundle_streams) == 7
    assert r.verifications == %{bundle_offline: :ok, chains: :ok}
  end

  test "the sim boundary is structural: non-sim chapters are refused, nothing appended" do
    head = Log.head()
    assert {:error, :not_a_sim_chapter} = Demo.run("chapter-genesis")
    assert Log.head() == head
  end

  test "repeatable: two fresh-chapter runs coexist and agree" do
    assert {:ok, first} = Demo.run("chapter-sim-run-1")
    assert {:ok, second} = Demo.run("chapter-sim-run-2")

    assert invariant(first) == invariant(second)
    assert :ok = Log.verify_chains()
  end
end
