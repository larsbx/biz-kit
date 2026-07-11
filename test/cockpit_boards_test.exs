defmodule CoopSubstrate.CockpitBoardsTest do
  @moduledoc """
  Phase 5B (docs/phase5b_plan.md P1–P5): every board number recomputes from
  (log, constants, caller clock); breach findings are exactly-once per
  (kind, period) so the sweep is idempotent by rejection; B_op is accounting
  never enforcement; absent numbers say so.
  """

  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.Cockpit
  alias CoopSubstrate.Harness.Ops
  alias CoopSubstrate.Log

  @chapter "chapter-genesis"
  # period_ms 1_000: period N covers [N*1000, (N+1)*1000).
  @now 5_500

  setup do
    steward = new_member("steward")
    author = new_member("author")

    for {name, value} <- %{
          "cockpit/open_cap" => 10,
          "cockpit/b_op" => 30,
          "cockpit/period_ms" => 1_000,
          "cockpit/cost_default" => 20
        } do
      {:ok, _} =
        Log.append(
          signed_event(author, "CharterConstantDeclared", %{"name" => name, "value" => value})
        )
    end

    %{steward: steward, author: author}
  end

  defp raise!(steward, id, attrs \\ []) do
    payload =
      Map.merge(
        %{
          "item_id" => id,
          "process" => "dispatch",
          "act_type" => "rate_con",
          "packet_refs" => ["p"],
          "recommendation" => "sign",
          "bounds" => %{},
          "compensation_path" => "retract",
          "deadline_ms" => 9_000,
          "basis_ref" => {:bytes, :crypto.strong_rand_bytes(32)}
        },
        Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
      )

    {:ok, _} = Log.append(signed_event(steward, "EscalationRaised", payload))
  end

  defp resolve!(steward, id, verdict, at_ms) do
    {:ok, _} =
      Log.append(
        signed_event(
          steward,
          "EscalationResolved",
          %{"item_id" => id, "verdict" => verdict},
          timestamp_ms: at_ms
        )
      )
  end

  test "board arithmetic: counts, approval rate, act heat, queue summary, fold health",
       ctx do
    raise!(ctx.steward, "R-1")
    raise!(ctx.steward, "R-2", act_type: "quote")
    raise!(ctx.steward, "R-3")
    raise!(ctx.steward, "R-h", process: "harness", deadline_ms: 4_000)

    resolve!(ctx.steward, "R-1", "approved", 5_100)
    resolve!(ctx.steward, "R-2", "declined", 5_200)

    {:ok, boards} = Cockpit.boards(@chapter, @now)

    assert boards.queue == %{open: 2, nearest_deadline_ms: 4_000}

    assert [dispatch, harness] = boards.processes
    assert %{process: "dispatch", raised: 3, open: 1, approved: 1, declined: 1, defects: 0} = dispatch
    assert dispatch.approval_rate == 0.5
    assert dispatch.act_heat == %{"rate_con" => 2, "quote" => 1}
    assert %{process: "harness", raised: 1, approval_rate: nil} = harness

    # B_op: two resolutions in period 5 × 20min = 40 > 30 ⇒ breach reported.
    assert %{configured: true, period_ref: 5, resolved_items: 2, spent_minutes: 40, breach: true} =
             boards.b_op

    assert boards.fold_health.head_seq > 0
    assert boards.veto_feed == :no_veto_eligible_acts_exist

    # Every number recomputes (P1): a second call is identical.
    assert {:ok, ^boards} = Cockpit.boards(@chapter, @now)

    # Accounting, never enforcement: despite the breach, the queue still
    # accepts items (P3).
    raise!(ctx.steward, "R-4")
  end

  test "period boundaries: resolutions land in THEIR period, not the caller's", ctx do
    raise!(ctx.steward, "R-1")
    raise!(ctx.steward, "R-2")
    resolve!(ctx.steward, "R-1", "approved", 4_900)
    resolve!(ctx.steward, "R-2", "approved", 5_100)

    {:ok, boards} = Cockpit.boards(@chapter, @now)
    assert %{period_ref: 5, resolved_items: 1, spent_minutes: 20, breach: false} = boards.b_op

    {:ok, earlier} = Cockpit.boards(@chapter, 4_999)
    assert %{period_ref: 4, resolved_items: 1} = earlier.b_op
  end

  test "unconfigured B_op says so; boards still render" do
    reset_log(%{})

    author = new_member("author")

    {:ok, _} =
      Log.append(
        signed_event(author, "CharterConstantDeclared", %{
          "name" => "cockpit/open_cap",
          "value" => 10
        })
      )

    {:ok, boards} = Cockpit.boards(@chapter, @now)
    assert boards.b_op == %{configured: false}
    assert boards.processes == []
  end

  test "the sweep: exactly-once per period, idempotent by rejection", ctx do
    {:ok, _} = Ops.gen_key("steward")
    dir = Application.fetch_env!(:coop_substrate, :harness_keys_dir)
    on_exit(fn -> File.rm_rf(dir) end)

    # No breach yet.
    assert {:ok, :no_breach} = Ops.guard_sweep(@now)

    raise!(ctx.steward, "R-1")
    raise!(ctx.steward, "R-2")
    resolve!(ctx.steward, "R-1", "approved", 5_100)
    resolve!(ctx.steward, "R-2", "declined", 5_200)

    assert {:ok, %{type: "StructuralFindingRaised"}} = Ops.guard_sweep(@now)

    # Re-run: idempotent by rejection (P2). The sweep's deterministic id
    # trips the id-uniqueness check first; the (kind, period) check backstops
    # non-deterministic emitters.
    assert {:error, {:reject, _, {:finding_already_raised, "F-b_op-5"}}} =
             Ops.guard_sweep(@now)

    gov = new_member("steward")

    assert {:error, {:reject, _, {:finding_exists_for_period, "b_op_breach", 5}}} =
             Log.append(
               signed_event(gov, "StructuralFindingRaised", %{
                 "finding_id" => "F-other-id",
                 "kind" => "b_op_breach",
                 "period_ref" => 5
               })
             )

    # A different period breaches independently.
    raise!(ctx.steward, "R-3")
    raise!(ctx.steward, "R-4")
    resolve!(ctx.steward, "R-3", "approved", 7_100)
    resolve!(ctx.steward, "R-4", "approved", 7_200)

    assert {:ok, %{type: "StructuralFindingRaised"}} = Ops.guard_sweep(7_500)
    assert :ok = Log.verify_chains()
  end
end
