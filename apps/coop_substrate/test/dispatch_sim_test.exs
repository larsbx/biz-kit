defmodule CoopSubstrate.DispatchSimTest do
  @moduledoc """
  Phase 8A (docs/phase8a_plan.md): the Dispatch-D 4A slice under an
  operator-directed simulation. `Sim.GateD` drives gate(D) true on a sim
  chapter through the REAL 2A–2D machinery (sim, not bypass — a control
  test keeps `BuildStarted` unrepresentable without evidence); the envelope
  is the member's signature and ceiling; tender routing that disagrees with
  the pure decision is unrepresentable; the published sim fixture set is
  the parser TDD corpus.
  """

  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.Canonical
  alias CoopSubstrate.Cockpit
  alias CoopSubstrate.Dispatch
  alias CoopSubstrate.Dispatch.Parser
  alias CoopSubstrate.Export
  alias CoopSubstrate.Harness
  alias CoopSubstrate.Harness.Artifacts
  alias CoopSubstrate.Log
  alias CoopSubstrate.Sim.GateD

  @lanes ["detroit->chicago"]
  @equipment ["dry_van"]
  @floor 150_000

  setup do
    {:ok, GateD.run()}
  end

  defp sim(ctx, actor, type, payload) do
    signed_event(actor, type, payload, chapter_id: ctx.chapter_id)
  end

  defp envelope_payload(ctx, version, params_overrides \\ %{}) do
    %{
      "member_id" => ctx.member_id,
      "entity_id" => ctx.entity_id,
      "scope" => "tender_accept",
      "version" => version,
      "params" =>
        Map.merge(
          %{"lanes" => @lanes, "equipment" => @equipment, "rate_floor_minor" => @floor},
          params_overrides
        )
    }
  end

  defp declare_envelope!(ctx, version) do
    {:ok, _} = Log.append(sim(ctx, ctx.carrier, "EnvelopeDeclared", envelope_payload(ctx, version)))
  end

  defp receive_tender!(ctx, tender_id, raw_text) do
    {:ok, raw_ref} = Artifacts.put(raw_text)

    {:ok, _} =
      Log.append(
        sim(ctx, ctx.steward, "TenderReceived", %{
          "tender_id" => tender_id,
          "member_id" => ctx.member_id,
          "entity_id" => ctx.entity_id,
          "raw_ref" => {:bytes, raw_ref}
        })
      )

    raw_ref
  end

  defp parse_tender!(ctx, tender_id, raw_ref, raw_text, grade) do
    {:ok, fields} = Parser.parse(raw_text)

    {:ok, _} =
      Log.append(
        sim(ctx, ctx.steward, "TenderParsed", %{
          "tender_id" => tender_id,
          "member_id" => ctx.member_id,
          "entity_id" => ctx.entity_id,
          "raw_ref" => {:bytes, raw_ref},
          "grade" => grade,
          "fields" => fields
        })
      )
  end

  defp decision_payload(ctx, tender_id, version, basis) do
    %{
      "tender_id" => tender_id,
      "member_id" => ctx.member_id,
      "entity_id" => ctx.entity_id,
      "envelope_version" => version,
      "basis" => basis
    }
  end

  defp fixture_content(ctx, name) do
    %{"content" => content} = Enum.find(ctx.fixtures, &(&1["name"] == name))
    content
  end

  test "acceptance 1: sim, not bypass — gate(D) true through the real pipeline; no evidence, no BuildStarted",
       ctx do
    assert {:ok, true} = Harness.gate(ctx.chapter_id, "D")
    assert is_integer(ctx.build_seq)

    # Control 1: on a chapter with no declared constants the gate is not
    # even evaluable — fails closed.
    steward = new_member("steward")

    assert {:error, {:reject, _, :constants_undeclared}} =
             Log.append(signed_event(steward, "BuildStarted", %{"section" => "D"}))

    # Control 2: constants declared but no evidence — still unrepresentable.
    author = new_member("author")

    for {name, value} <- %{"harness/D/n" => 2, "harness/D/c" => 1, "harness/D/d" => 1, "k" => 2} do
      {:ok, _} =
        Log.append(
          signed_event(author, "CharterConstantDeclared", %{"name" => name, "value" => value})
        )
    end

    assert {:error, {:reject, _, {:harness_gate_not_passed, "D"}}} =
             Log.append(signed_event(steward, "BuildStarted", %{"section" => "D"}))
  end

  test "acceptance 2: the envelope is the member's signature and ceiling", ctx do
    # A foreign member key cannot declare the carrier's envelope.
    attacker = new_member("member")

    assert {:error, {:reject, _, {:not_the_members_current_key, _}}} =
             Log.append(sim(ctx, attacker, "EnvelopeDeclared", envelope_payload(ctx, 1)))

    # Malformed params never land.
    assert {:error, {:reject, _, :malformed_envelope_params}} =
             Log.append(
               sim(ctx, ctx.carrier, "EnvelopeDeclared", envelope_payload(ctx, 1, %{"lanes" => []}))
             )

    assert {:error, {:reject, _, {:unknown_envelope_scope, "invoice"}}} =
             Log.append(
               sim(ctx, ctx.carrier, "EnvelopeDeclared", %{
                 envelope_payload(ctx, 1)
                 | "scope" => "invoice"
               })
             )

    # Versions are strictly monotonic, across revocation too (10 P6).
    assert {:error, {:reject, _, {:envelope_version_not_monotonic, 3}}} =
             Log.append(sim(ctx, ctx.carrier, "EnvelopeDeclared", envelope_payload(ctx, 3)))

    declare_envelope!(ctx, 1)

    revoke = %{
      "member_id" => ctx.member_id,
      "entity_id" => ctx.entity_id,
      "scope" => "tender_accept",
      "version" => 1
    }

    {:ok, _} = Log.append(sim(ctx, ctx.carrier, "EnvelopeRevoked", revoke))

    assert {:error, {:reject, _, :no_active_envelope}} =
             Log.append(sim(ctx, ctx.carrier, "EnvelopeRevoked", revoke))

    assert {:error, {:reject, _, {:envelope_version_not_monotonic, 1}}} =
             Log.append(sim(ctx, ctx.carrier, "EnvelopeDeclared", envelope_payload(ctx, 1)))

    declare_envelope!(ctx, 2)
  end

  test "acceptance 3+4: routing is gate-recomputed; the fixture set is the parser corpus", ctx do
    # Parser green over every published fixture, fetched by hash (11 §1.5).
    {:ok, bytes} = Artifacts.get(ctx.fixture_hash)
    {:ok, %{"schema" => "FixtureSetV1", "fixtures" => fixtures}} = Canonical.decode(bytes)
    assert length(fixtures) == 3

    for %{"name" => name, "content" => content} <- fixtures do
      assert {:ok, %{"lane" => _, "rate_minor" => _, "equipment" => _}} = Parser.parse(content),
             "fixture #{name} failed to parse"
    end

    declare_envelope!(ctx, 1)

    # In-envelope at/above floor: accept — and ONLY accept — is representable.
    raw1 = fixture_content(ctx, "tender_in_envelope.txt")
    ref1 = receive_tender!(ctx, "T-1", raw1)
    parse_tender!(ctx, "T-1", ref1, raw1, "human")

    assert {:ok, {:accept, 1, basis}} = Dispatch.route(ctx.chapter_id, "T-1")

    assert {:error, {:reject, _, {:decision_mismatch, :accept}}} =
             Log.append(sim(ctx, ctx.steward, "TenderDeclined", decision_payload(ctx, "T-1", 1, basis)))

    assert {:error, {:reject, _, :decision_basis_mismatch}} =
             Log.append(
               sim(ctx, ctx.steward, "TenderAccepted", decision_payload(ctx, "T-1", 1, "because"))
             )

    {:ok, _} = Log.append(sim(ctx, ctx.steward, "TenderAccepted", decision_payload(ctx, "T-1", 1, basis)))

    assert {:error, {:reject, _, {:tender_already_decided, :accepted}}} =
             Log.append(sim(ctx, ctx.steward, "TenderAccepted", decision_payload(ctx, "T-1", 1, basis)))

    # In-envelope below floor: decline is the declared answer.
    raw2 = fixture_content(ctx, "tender_below_floor.txt")
    ref2 = receive_tender!(ctx, "T-2", raw2)
    parse_tender!(ctx, "T-2", ref2, raw2, "human")

    assert {:ok, {:decline, 1, basis2}} = Dispatch.route(ctx.chapter_id, "T-2")

    assert {:error, {:reject, _, {:decision_mismatch, :decline}}} =
             Log.append(sim(ctx, ctx.steward, "TenderAccepted", decision_payload(ctx, "T-2", 1, basis2)))

    {:ok, _} = Log.append(sim(ctx, ctx.steward, "TenderDeclined", decision_payload(ctx, "T-2", 1, basis2)))

    # Off-lane: neither accept nor decline is representable — only the R rail.
    raw3 = fixture_content(ctx, "tender_off_lane.txt")
    ref3 = receive_tender!(ctx, "T-3", raw3)
    parse_tender!(ctx, "T-3", ref3, raw3, "human")

    assert {:ok, {:escalate, {:out_of_envelope, :lane}}} = Dispatch.route(ctx.chapter_id, "T-3")

    for {type, verdict} <- [{"TenderAccepted", "a"}, {"TenderDeclined", "d"}] do
      assert {:error, {:reject, _, {:decision_requires_escalation, {:out_of_envelope, :lane}}}} =
               Log.append(sim(ctx, ctx.steward, type, decision_payload(ctx, "T-3", 1, verdict)))
    end

    {:ok, _} =
      Log.append(
        sim(ctx, ctx.steward, "EscalationRaised", %{
          "item_id" => "tender/T-3",
          "process" => "tender_accept",
          "act_type" => "tender_decision",
          "packet_refs" => [Base.encode16(ref3, case: :lower)],
          "recommendation" => "call the broker back; off-lane ask",
          "bounds" => %{"scope" => "tender_accept"},
          "compensation_path" => "decline after the call",
          "deadline_ms" => 4_102_444_800_000,
          "basis_ref" => {:bytes, ref3}
        })
      )

    assert {:ok, [%{item_id: "tender/T-3"}]} = Cockpit.queue(ctx.chapter_id)

    # Machine parse demotes to R; a human re-parse promotes (08 §7).
    ref4 = receive_tender!(ctx, "T-4", raw1)
    parse_tender!(ctx, "T-4", ref4, raw1, "machine")

    assert {:ok, {:escalate, :low_grade_parse}} = Dispatch.route(ctx.chapter_id, "T-4")

    assert {:error, {:reject, _, {:decision_requires_escalation, :low_grade_parse}}} =
             Log.append(sim(ctx, ctx.steward, "TenderAccepted", decision_payload(ctx, "T-4", 1, basis)))

    parse_tender!(ctx, "T-4", ref4, raw1, "human")
    {:ok, _} = Log.append(sim(ctx, ctx.steward, "TenderAccepted", decision_payload(ctx, "T-4", 1, basis)))

    # Sovereignty of exhaust: the rail rides the member's departure bundle.
    {:ok, bundle} = Export.member_bundle(ctx.chapter_id, ctx.member_id)
    assert Map.has_key?(bundle.streams, "#{ctx.chapter_id}/envelopes/#{ctx.member_id}/#{ctx.entity_id}")
    assert Map.has_key?(bundle.streams, "#{ctx.chapter_id}/tenders/#{ctx.member_id}/#{ctx.entity_id}")
    assert {:ok, _} = Export.verify(bundle)
  end

  test "revocation is atomic and the gate survives restart", ctx do
    declare_envelope!(ctx, 1)
    raw = fixture_content(ctx, "tender_in_envelope.txt")
    ref = receive_tender!(ctx, "T-9", raw)
    parse_tender!(ctx, "T-9", ref, raw, "human")

    {:ok, _} =
      Log.append(
        sim(ctx, ctx.carrier, "EnvelopeRevoked", %{
          "member_id" => ctx.member_id,
          "entity_id" => ctx.entity_id,
          "scope" => "tender_accept",
          "version" => 1
        })
      )

    assert {:ok, {:escalate, :no_envelope}} = Dispatch.route(ctx.chapter_id, "T-9")

    reject =
      {:error, {:reject, 0, {:decision_requires_escalation, :no_envelope}}}

    assert reject ==
             Log.append(sim(ctx, ctx.steward, "TenderAccepted", decision_payload(ctx, "T-9", 1, "x")))

    # The rebuilt gate draws the same line, and history verifies.
    restart_log()

    assert reject ==
             Log.append(sim(ctx, ctx.steward, "TenderAccepted", decision_payload(ctx, "T-9", 1, "x")))

    assert :ok = Log.verify_chains()
  end
end
