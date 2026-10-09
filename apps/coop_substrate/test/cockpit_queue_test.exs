defmodule CoopSubstrate.CockpitQueueTest do
  @moduledoc """
  Phase 5A (docs/phase5a_plan.md P1–P6): decision-ready is structural,
  flooding is capped and fails closed undeclared, the queue is a pure
  deadline-ordered fold, resolutions close exactly their item once, and
  returned_defect is terminal for the id.
  """

  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.Cockpit
  alias CoopSubstrate.Log

  @chapter "chapter-genesis"

  setup do
    %{steward: new_member("steward"), author: new_member("author")}
  end

  defp declare_cap!(author, cap) do
    {:ok, _} =
      Log.append(
        signed_event(author, "CharterConstantDeclared", %{
          "name" => "cockpit/open_cap",
          "value" => cap
        })
      )
  end

  defp item(steward, id, attrs \\ []) do
    payload =
      Map.merge(
        %{
          "item_id" => id,
          "process" => "dispatch",
          "act_type" => "rate_con_novel_terms",
          "packet_refs" => [Base.encode16(:crypto.strong_rand_bytes(8))],
          "recommendation" => "sign — terms match the envelope pattern",
          "bounds" => %{"max_minor" => 250_000},
          "compensation_path" => "retraction event within 24h",
          "deadline_ms" => 1_700_000_500_000,
          "basis_ref" => {:bytes, :crypto.strong_rand_bytes(32)}
        },
        Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
      )

    signed_event(steward, "EscalationRaised", payload)
  end

  defp resolve(steward, id, verdict, attrs \\ []) do
    signed_event(
      steward,
      "EscalationResolved",
      Map.merge(
        %{"item_id" => id, "verdict" => verdict},
        Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
      )
    )
  end

  defp assert_rejected(envelope, expected_reason) do
    before_head = Log.head()
    assert {:error, {:reject, _i, reason}} = Log.append(envelope)
    assert reason == expected_reason
    assert Log.head() == before_head
    assert :ok = Log.verify_chains()
  end

  test "decision-ready is structural; the cap fails closed undeclared", ctx do
    # No cap declared: no representable escalation (P3, fail closed).
    assert_rejected(item(ctx.steward, "R-1"), :constants_undeclared)

    declare_cap!(ctx.author, 2)

    # Shape: a missing decision-ready field never even BUILDS an envelope —
    # the registry rejects at construction (stronger than an append reject).
    assert {:error, {:payload_invalid, {:missing_fields, ["recommendation"]}}} =
             CoopSubstrate.Protocol.Envelope.new(%{
               chapter_id: @chapter,
               type: "EscalationRaised",
               payload: %{
                 "item_id" => "R-x",
                 "process" => "dispatch",
                 "act_type" => "a",
                 "packet_refs" => ["p"],
                 "bounds" => %{},
                 "compensation_path" => "c",
                 "deadline_ms" => 1,
                 "basis_ref" => {:bytes, :crypto.strong_rand_bytes(32)}
               },
               signers: [ctx.steward.signer],
               timestamp_ms: System.system_time(:millisecond)
             })

    # ...and the gate rejects hollow decision-readiness (P1).
    assert_rejected(item(ctx.steward, "R-x", packet_refs: []), :packet_refs_required)
    assert_rejected(item(ctx.steward, "R-x", deadline_ms: 0), :bad_deadline)
    assert_rejected(item(ctx.steward, "R-x", recommendation: ""), :decision_ready_fields_empty)

    {:ok, _} = Log.append(item(ctx.steward, "R-1"))
    assert_rejected(item(ctx.steward, "R-1"), {:item_already_raised, "R-1"})
  end

  test "flooding: the cap binds per process; a resolution frees the slot", ctx do
    declare_cap!(ctx.author, 2)

    {:ok, _} = Log.append(item(ctx.steward, "R-1"))
    {:ok, _} = Log.append(item(ctx.steward, "R-2"))
    assert_rejected(item(ctx.steward, "R-3"), {:queue_flooded, "dispatch", 2})

    # Another process has its own headroom.
    {:ok, _} = Log.append(item(ctx.steward, "R-h", process: "harness"))

    {:ok, _} = Log.append(resolve(ctx.steward, "R-1", "declined"))
    {:ok, _} = Log.append(item(ctx.steward, "R-3"))
  end

  test "resolution discipline and returned_defect finality", ctx do
    declare_cap!(ctx.author, 5)
    {:ok, _} = Log.append(item(ctx.steward, "R-1"))

    assert_rejected(resolve(ctx.steward, "R-404", "approved"), {:unknown_item, "R-404"})
    assert_rejected(resolve(ctx.steward, "R-1", "maybe"), {:unknown_verdict, "maybe"})

    {:ok, _} =
      Log.append(resolve(ctx.steward, "R-1", "returned_defect", reason: "stale packet fold"))

    assert_rejected(resolve(ctx.steward, "R-1", "approved"), {:item_already_resolved, "R-1"})

    # Terminal for the ID (P5): completeness arrives as a NEW item.
    assert_rejected(item(ctx.steward, "R-1"), {:item_already_raised, "R-1"})
    {:ok, _} = Log.append(item(ctx.steward, "R-1b"))
  end

  test "the queue: deadline-ordered pure fold, as_of-reproducible", ctx do
    declare_cap!(ctx.author, 5)

    {:ok, _} = Log.append(item(ctx.steward, "R-late", deadline_ms: 3_000))
    {:ok, [early_env]} = Log.append(item(ctx.steward, "R-early", deadline_ms: 1_000))
    {:ok, _} = Log.append(item(ctx.steward, "R-tie-b", deadline_ms: 2_000))
    {:ok, _} = Log.append(item(ctx.steward, "R-tie-a", deadline_ms: 2_000))

    {:ok, queue} = Cockpit.queue(@chapter)

    assert Enum.map(queue, & &1.item_id) == ["R-early", "R-tie-a", "R-tie-b", "R-late"]

    {:ok, _} = Log.append(resolve(ctx.steward, "R-early", "approved"))
    {:ok, queue} = Cockpit.queue(@chapter)
    assert Enum.map(queue, & &1.item_id) == ["R-tie-a", "R-tie-b", "R-late"]

    # The pre-resolution queue is reproducible forever (P2)... though R-tie-*
    # arrived later, as_of at R-early's append shows exactly the two then open.
    {:ok, as_of_queue} = Cockpit.queue(@chapter, as_of: early_env.global_seq)
    assert Enum.map(as_of_queue, & &1.item_id) == ["R-early", "R-late"]
  end

  test "tasks: queue lists, decide resolves with --yes", ctx do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    declare_cap!(ctx.author, 5)
    {:ok, _} = CoopSubstrate.Harness.Ops.gen_key("steward")

    dir = Application.fetch_env!(:coop_substrate, :harness_keys_dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, _} = Log.append(item(ctx.steward, "R-1"))

    Mix.Tasks.Cockpit.Queue.run([])
    assert_received {:mix_shell, :info, ["item=R-1" <> rest]}
    assert rest =~ "process=dispatch"

    Mix.Tasks.Cockpit.Decide.run(["R-1", "approved", "--reason", "in pattern", "--yes"])
    assert_received {:mix_shell, :info, ["event=" <> _]}

    Mix.Tasks.Cockpit.Queue.run([])
    assert_received {:mix_shell, :info, ["queue empty"]}
  end
end
