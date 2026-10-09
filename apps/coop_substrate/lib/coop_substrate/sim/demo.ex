defmodule CoopSubstrate.Sim.Demo do
  @moduledoc """
  **SIMULATION ONLY** — the demo entry point (Phase 11A,
  docs/phase11a_plan.md). Drives the whole simulated cycle on a sim
  chapter and returns every number and verification verdict:

  sim gate(D) through the real pipeline → member envelope + rate terms →
  the three fixture tenders routed (accept / decline / escalate) → the
  escalation approved and consumed (9B) → the accepted tender dispatched
  and tracked with detention → gate-recomputed invoice, credit memo,
  dunning step → demo kit + guards (8D) → obligation-rail ring, executed
  netting round (9A) → the carrier's departure bundle verified offline
  (6B) → chain audit.

  The sim boundary is structural: `run/1` refuses any chapter id not
  prefixed `chapter-sim`, and each run defaults to a fresh uniquely
  suffixed chapter (chapters are isolated; nothing is reset). Nothing
  produced here is field evidence or a campaign asset — the real demo
  compiles only from real books behind `gate(D)` (13 §6).

  `mix coop.demo` prints this module's result; every printed number
  exists in the returned map first.
  """

  alias CoopSubstrate.Cockpit
  alias CoopSubstrate.Crypto
  alias CoopSubstrate.Dispatch
  alias CoopSubstrate.Export
  alias CoopSubstrate.Finance
  alias CoopSubstrate.Harness
  alias CoopSubstrate.Harness.Artifacts
  alias CoopSubstrate.Log
  alias CoopSubstrate.Protocol.Envelope
  alias CoopSubstrate.Sim.GateD
  alias CoopSubstrate.StakeView

  @t0 1_752_000_000_000
  @minute 60_000

  @doc """
  Run the canonical demo scenario. With no argument, a fresh
  `chapter-sim-demo-<ms>` chapter; any explicit chapter id must be
  `chapter-sim`-prefixed or the run is refused with
  `{:error, :not_a_sim_chapter}` before anything is appended.
  """
  def run(chapter_id \\ nil)

  def run(nil),
    do: run("chapter-sim-demo-" <> Integer.to_string(System.system_time(:millisecond)))

  def run(chapter_id) when is_binary(chapter_id) do
    if String.starts_with?(chapter_id, "chapter-sim") do
      {:ok, execute(chapter_id)}
    else
      {:error, :not_a_sim_chapter}
    end
  end

  defp execute(ch) do
    ctx = GateD.run(ch)
    base = %{"member_id" => ctx.member_id, "entity_id" => ctx.entity_id}
    author = actor("author")

    # The carrier's declared ceiling and terms (member-signed, versioned).
    append!(
      ch,
      ctx.carrier,
      "EnvelopeDeclared",
      Map.merge(base, %{
        "scope" => "tender_accept",
        "version" => 1,
        "params" => %{
          "lanes" => ["detroit->chicago"],
          "equipment" => ["dry_van"],
          "rate_floor_minor" => 150_000
        }
      })
    )

    append!(
      ch,
      ctx.carrier,
      "RateTermsDeclared",
      Map.merge(base, %{
        "version" => 1,
        "params" => %{
          "free_time_minutes" => 120,
          "detention_rate_minor_per_hour" => 6_000,
          "dunning_rungs" => ["reminder", "final_notice"]
        }
      })
    )

    append!(ch, author, "CharterConstantDeclared", %{
      "name" => "dispatch/minutes_per_check_call",
      "value" => 15
    })

    # The tender rail: the published fixtures are the input corpus.
    routing =
      Map.new(Enum.zip(["T-1", "T-2", "T-3"], ctx.fixtures), fn {tender_id, fixture} ->
        {tender_id, route_tender!(ch, ctx, base, tender_id, fixture)}
      end)

    {:ok, queue_before} = Cockpit.queue(ch)

    # The R rail consumes its approval (9B).
    append!(ch, ctx.steward, "EscalationResolved", %{
      "item_id" => "tender/T-3",
      "verdict" => "approved"
    })

    append!(
      ch,
      ctx.steward,
      "TenderAccepted",
      Map.merge(base, %{
        "tender_id" => "T-3",
        "envelope_version" => 0,
        "basis" => "r/tender/T-3",
        "authorization_item_id" => "tender/T-3"
      })
    )

    {:ok, queue_after} = Cockpit.queue(ch)

    # A load's life: dispatched, tracked with detention, invoiced.
    append!(
      ch,
      ctx.steward,
      "LoadDispatched",
      Map.merge(base, %{
        "load_id" => "L-1",
        "tender_id" => "T-1"
      })
    )

    for {type, payload} <- [
          {"AppointmentRecorded", %{"stop" => "pickup", "appointment_ms" => @t0}},
          {"LoadArrived", %{"stop" => "pickup", "occurred_ms" => @t0}},
          {"StatusRecorded", %{"status" => "loaded", "occurred_ms" => @t0 + 10 * @minute}},
          {"LoadDeparted", %{"stop" => "pickup", "occurred_ms" => @t0 + 200 * @minute}},
          {"StatusRecorded", %{"status" => "in_transit", "occurred_ms" => @t0 + 300 * @minute}},
          {"LoadArrived", %{"stop" => "delivery", "occurred_ms" => @t0 + 500 * @minute}},
          {"LoadDeparted", %{"stop" => "delivery", "occurred_ms" => @t0 + 560 * @minute}},
          {"StatusRecorded", %{"status" => "delivered", "occurred_ms" => @t0 + 560 * @minute}}
        ] do
      append!(ch, ctx.steward, type, Map.merge(base, Map.put(payload, "load_id", "L-1")))
    end

    {:ok, dwell} = Dispatch.dwell(ch, "L-1")
    {:ok, invoice} = Dispatch.compute_invoice(ch, "L-1")

    append!(
      ch,
      ctx.steward,
      "InvoiceIssued",
      Map.merge(base, %{
        "invoice_id" => "INV-1",
        "load_id" => "L-1",
        "terms_version" => invoice.terms_version,
        "lines" => invoice.lines,
        "amount_minor" => invoice.amount_minor
      })
    )

    append!(
      ch,
      ctx.steward,
      "CreditMemoIssued",
      Map.merge(base, %{
        "memo_id" => "CM-1",
        "invoice_id" => "INV-1",
        "amount_minor" => 3_000,
        "reason" => "goodwill on the detention line"
      })
    )

    append!(
      ch,
      ctx.steward,
      "DunningStepped",
      Map.merge(base, %{
        "invoice_id" => "INV-1",
        "rung_index" => 0,
        "rung" => "reminder"
      })
    )

    {:ok, kit} = Dispatch.demo_kit(ch, ctx.member_id, ctx.entity_id)
    {:ok, guards} = Dispatch.guards(ch)

    # The obligation rail: a ring, then an executed netting round (9A).
    netting = run_obligation_rail!(ch)

    # The member's own answer to "what do I have?" (11B) — trimmed to the
    # run-invariant facts; agreement with the demo kit is asserted, and
    # per-run-random key ids stay out of the result.
    {:ok, stake} = StakeView.view(ch, ctx.member_id, at: @t0)
    entity = stake.memberships[ctx.entity_id]

    stake_section = %{
      membership_state: entity.state,
      capital_balance_minor: entity.capital.balance_minor,
      obligation_edges: length(stake.obligations),
      dispatch_agrees: entity.dispatch == kit
    }

    # Portability + honesty at the CURRENT strength (12A/12B): checkpoint,
    # anchor, and verify the bundle self-contained — no key material passed
    # in — then check the derived genesis against the sim's own root. The
    # 6B plain verification stays alongside as the baseline it is.
    {:ok, checkpoint_blob} =
      Log.checkpoint(ch, ctx.checkpoint.signer.key_id, ctx.checkpoint.seed)

    {:ok, bundle} = Export.member_bundle(ch, ctx.member_id)
    {:ok, anchored} = Export.anchor(bundle, checkpoint_blob)

    {anchored_verdict, genesis_verdict} =
      case Export.verify_anchored(anchored) do
        {:ok, %{genesis_key: genesis}} ->
          {:ok, if(genesis == ctx.governance.signer.pubkey, do: :ok, else: :mismatch)}

        {:error, reason} ->
          {{:error, reason}, :not_derived}
      end

    %{
      chapter_id: ch,
      gate: Harness.gate(ch, "D"),
      build_seq: ctx.build_seq,
      routing: routing,
      r_queue: %{
        before_consumption: Enum.map(queue_before, & &1.item_id),
        after_consumption: Enum.map(queue_after, & &1.item_id)
      },
      dwell: dwell,
      invoice: invoice,
      demo_kit: kit,
      guards: guards,
      stake_view: stake_section,
      netting: netting,
      bundle_streams: anchored.streams |> Map.keys() |> Enum.sort(),
      verifications: %{
        bundle_offline: with({:ok, _} <- Export.verify(bundle), do: :ok),
        bundle_anchored: anchored_verdict,
        genesis: genesis_verdict,
        chains: Log.verify_chains()
      }
    }
  end

  defp route_tender!(ch, ctx, base, tender_id, %{"content" => content}) do
    {:ok, raw_ref} = Artifacts.put(content)
    {:ok, fields} = Dispatch.Parser.parse(content)

    append!(
      ch,
      ctx.steward,
      "TenderReceived",
      Map.merge(base, %{
        "tender_id" => tender_id,
        "raw_ref" => {:bytes, raw_ref}
      })
    )

    append!(
      ch,
      ctx.steward,
      "TenderParsed",
      Map.merge(base, %{
        "tender_id" => tender_id,
        "raw_ref" => {:bytes, raw_ref},
        "grade" => "human",
        "fields" => fields
      })
    )

    {:ok, decision} = Dispatch.route(ch, tender_id)

    case decision do
      {:accept, version, basis} ->
        append!(
          ch,
          ctx.steward,
          "TenderAccepted",
          Map.merge(base, %{
            "tender_id" => tender_id,
            "envelope_version" => version,
            "basis" => basis
          })
        )

      {:decline, version, basis} ->
        append!(
          ch,
          ctx.steward,
          "TenderDeclined",
          Map.merge(base, %{
            "tender_id" => tender_id,
            "envelope_version" => version,
            "basis" => basis
          })
        )

      {:escalate, _reason} ->
        append!(ch, ctx.steward, "EscalationRaised", %{
          "item_id" => "tender/" <> tender_id,
          "process" => "tender_accept",
          "act_type" => "tender_decision",
          "packet_refs" => [Base.encode16(raw_ref, case: :lower)],
          "recommendation" => "operator judgment on the off-lane ask",
          "bounds" => %{"scope" => "tender_accept"},
          "compensation_path" => "decline after the call",
          "deadline_ms" => 4_102_444_800_000,
          "basis_ref" => {:bytes, raw_ref}
        })
    end

    decision
  end

  defp run_obligation_rail!(ch) do
    members =
      Map.new(["M-ada", "M-bob", "M-carol"], fn id ->
        a = actor("member")

        append!(ch, a, "MemberRegistered", %{
          "member_id" => id,
          "pubkey" => {:bytes, a.signer.pubkey},
          "key_id" => a.signer.key_id
        })

        {id, a}
      end)

    obligate! = fn id, debtor, creditor, amount ->
      append_multi!(
        ch,
        [as_role(members[debtor], "debtor"), as_role(members[creditor], "creditor")],
        "ObligationRecorded",
        %{
          "obligation_id" => id,
          "debtor_id" => debtor,
          "creditor_id" => creditor,
          "amount_minor" => amount,
          "denomination" => "USD"
        }
      )
    end

    obligate!.("OB-1", "M-ada", "M-bob", 100_000)
    obligate!.("OB-2", "M-bob", "M-ada", 60_000)
    obligate!.("OB-3", "M-bob", "M-carol", 50_000)
    obligate!.("OB-4", "M-carol", "M-ada", 70_000)

    {:ok, report_before} = Finance.netting(ch, {"M-ada", "M-bob"})
    {:ok, rings_before} = Finance.ring_stats(ch)

    append_multi!(
      ch,
      [as_role(members["M-ada"], "party_a"), as_role(members["M-bob"], "party_b")],
      "NettingExecuted",
      %{
        "party_a" => "M-ada",
        "party_b" => "M-bob",
        "denomination" => "USD",
        "a_to_b" => 100_000,
        "b_to_a" => 60_000,
        "setoff" => 60_000,
        "residual_obligation_id" => "OB-NET-1",
        "net_debtor" => "M-ada",
        "net_creditor" => "M-bob",
        "net_minor" => 40_000
      }
    )

    {:ok, report_after} = Finance.netting(ch, {"M-ada", "M-bob"})
    {:ok, rings_after} = Finance.ring_stats(ch)

    %{
      report_before: report_before,
      rings_before: rings_before,
      report_after: report_after,
      rings_after: rings_after
    }
  end

  defp actor(role) do
    {pubkey, seed} = Crypto.generate_keypair()
    key_id = "sim-" <> Base.encode16(binary_part(pubkey, 0, 4), case: :lower)
    %{seed: seed, signer: %{role: role, pubkey: pubkey, key_id: key_id}}
  end

  defp as_role(actor, role), do: %{actor | signer: %{actor.signer | role: role}}

  defp append!(ch, actor, type, payload), do: append_multi!(ch, [actor], type, payload)

  defp append_multi!(ch, actors, type, payload) do
    {:ok, envelope} =
      Envelope.new(%{
        chapter_id: ch,
        type: type,
        payload: payload,
        signers: Enum.map(actors, & &1.signer),
        timestamp_ms: System.system_time(:millisecond)
      })

    signed =
      Enum.reduce(actors, envelope, fn a, env ->
        {:ok, s} = Envelope.sign(env, a.signer.key_id, a.seed)
        s
      end)

    {:ok, _} = Log.append(signed)
  end
end
