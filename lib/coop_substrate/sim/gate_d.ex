defmodule CoopSubstrate.Sim.GateD do
  @moduledoc """
  **SIMULATION ONLY** (Phase 8A, docs/phase8a_plan.md — operator-directed).

  Drives `gate(D)` true on a sim chapter through the REAL 2A–2D machinery —
  synthetic consented interviewees, findings, corroboration, a collected
  document, a compiled model, an adopted spec, and a published fixture set —
  then appends `BuildStarted{section: "D"}`, which the append gate accepts
  because the gate genuinely holds over that synthetic log. Nothing here
  touches the gate itself; the dispatch-sim suite keeps a control test
  proving `BuildStarted` stays unrepresentable without the evidence.

  Every actor and datum is synthetic and every chapter this runs on is a
  simulation world (`chapter-sim-*` by convention). Sim artifacts are NOT
  field evidence: the real Phase 4A brief, the founder campaign, and every
  counsel-governed surface stay gated on real, consented field data
  (docs/handoff_dispatch_d.md; docs/runbook_gate_d.md).
  """

  alias CoopSubstrate.Crypto
  alias CoopSubstrate.Harness
  alias CoopSubstrate.Harness.Fixtures
  alias CoopSubstrate.Harness.Synthesis
  alias CoopSubstrate.Log
  alias CoopSubstrate.Protocol.Envelope

  @member_id "M-sim-carrier"
  @entity_id "E-sim-carrier"

  # The sim fixture set doubles as the parser TDD corpus (corpus 11 §1.5,
  # 08 §7): plain-text tenders in the v0 `key: value` format, anonymized.
  @tender_fixtures [
    %{
      "name" => "tender_in_envelope.txt",
      "content" =>
        "lane: detroit->chicago\nrate_minor: 210000\nequipment: dry_van\nbroker: [REDACTED]"
    },
    %{
      "name" => "tender_below_floor.txt",
      "content" =>
        "lane: detroit->chicago\nrate_minor: 90000\nequipment: dry_van\nbroker: [REDACTED]"
    },
    %{
      "name" => "tender_off_lane.txt",
      "content" =>
        "lane: miami->atlanta\nrate_minor: 250000\nequipment: reefer\nbroker: [REDACTED]"
    }
  ]

  @doc """
  Run the full simulated pipeline on `chapter_id` (default `"chapter-sim-1"`).

  Returns the sim world: the synthetic actors (steward, carrier member,
  governance), the seeded carrier membership ids, the adopted-spec hashes,
  and the published fixture set (with its hash) for parser tests.
  """
  def run(chapter_id \\ "chapter-sim-1") do
    steward = actor("steward")
    carrier = actor("member")
    gov = actor("governance")
    author = actor("author")
    alice = actor("interviewee")
    bob = actor("interviewee")
    {key_id, seed} = {steward.signer.key_id, steward.seed}

    for {name, value} <- %{
          "harness/D/n" => 2,
          "harness/D/c" => 1,
          "harness/D/d" => 1,
          "k" => 2,
          "cockpit/open_cap" => 8
        } do
      append!(chapter_id, author, "CharterConstantDeclared", %{"name" => name, "value" => value})
    end

    seed_carrier_membership(chapter_id, steward, carrier)

    for {ivee, ref} <- [{alice, "SIM-IV-1"}, {bob, "SIM-IV-2"}] do
      append!(chapter_id, ivee, "InterviewConsentGranted", %{
        "interviewee_ref" => ref,
        "pubkey" => {:bytes, ivee.signer.pubkey},
        "key_id" => ivee.signer.key_id,
        "classes" => ["synthesis", "anonymized_fixtures", "prospect_record"],
        "recording" => false
      })
    end

    append!(chapter_id, steward, "InstrumentVersionPublished", %{
      "section" => "D",
      "version" => 1,
      "tree_hash" => {:bytes, :crypto.strong_rand_bytes(32)}
    })

    for {id, ref} <- [{"SIM-I-1", "SIM-IV-1"}, {"SIM-I-2", "SIM-IV-2"}] do
      append!(chapter_id, steward, "InterviewConducted", %{
        "section" => "D",
        "interview_id" => id,
        "interviewee_ref" => ref,
        "mode" => "form",
        "instrument_version" => 1
      })
    end

    for {fid, iid, kind, body} <- [
          {"SIM-F-1", "SIM-I-1", "process_step", "tenders arrive by email, accepted same hour"},
          {"SIM-F-2", "SIM-I-2", "process_step", "email tenders; declared lanes and a rate floor"},
          {"SIM-F-3", "SIM-I-2", "exception", "off-lane asks get a call back, never an auto-yes"}
        ] do
      append!(chapter_id, steward, "FindingExtracted", %{
        "finding_id" => fid,
        "interview_ref" => iid,
        "kind" => kind,
        "body" => body
      })
    end

    append!(chapter_id, steward, "Corroborated", %{
      "claim_ref" => "SIM-C-1",
      "finding_refs" => ["SIM-F-1", "SIM-F-2"]
    })

    {:ok, _} =
      Harness.collect_document(
        chapter_id,
        "SIM-I-1",
        "rate_confirmation",
        "redacted sim rate confirmation",
        key_id,
        seed
      )

    {:ok, _} = Synthesis.publish_model(chapter_id, "D", key_id, seed)

    {:ok, %{spec_hash: spec_hash, envelope_defaults_hash: defaults_hash, model_hash: model_hash}} =
      Synthesis.publish_spec(chapter_id, "D", %{"SIM-C-1" => %{"enveloped" => true}})

    append!(chapter_id, gov, "SpecAdopted", %{
      "section" => "D",
      "spec_hash" => {:bytes, spec_hash},
      "envelope_defaults_hash" => {:bytes, defaults_hash},
      "model_hash" => {:bytes, model_hash}
    })

    {:ok, %{fixture_hash: fixture_hash}} =
      Fixtures.publish(
        chapter_id,
        "D",
        @tender_fixtures,
        [],
        ["SIM-I-1", "SIM-I-2"],
        key_id,
        seed
      )

    {:ok, true} = Harness.gate(chapter_id, "D")
    {:ok, [build]} = append!(chapter_id, steward, "BuildStarted", %{"section" => "D"})

    %{
      chapter_id: chapter_id,
      steward: steward,
      carrier: carrier,
      governance: gov,
      member_id: @member_id,
      entity_id: @entity_id,
      spec_hash: spec_hash,
      envelope_defaults_hash: defaults_hash,
      fixture_hash: fixture_hash,
      fixtures: @tender_fixtures,
      build_seq: build.global_seq
    }
  end

  defp seed_carrier_membership(chapter_id, steward, carrier) do
    mp = %{"member_id" => @member_id, "entity_id" => @entity_id}

    append!(chapter_id, steward, "EntityRegistered", %{
      "entity_id" => @entity_id,
      "class" => "carriers_coop"
    })

    append!(chapter_id, carrier, "MemberRegistered", %{
      "member_id" => @member_id,
      "pubkey" => {:bytes, carrier.signer.pubkey},
      "key_id" => carrier.signer.key_id
    })

    append!(chapter_id, steward, "MembershipInvited", Map.put(mp, "class", "carriers_coop"))
    append!(chapter_id, carrier, "MembershipProbationStarted", mp)
    append_multi!(chapter_id, [carrier, steward], "MembershipConfirmed", mp)
  end

  defp actor(role) do
    {pubkey, seed} = Crypto.generate_keypair()
    key_id = "sim-" <> Base.encode16(binary_part(pubkey, 0, 4), case: :lower)
    %{seed: seed, signer: %{role: role, pubkey: pubkey, key_id: key_id}}
  end

  defp append!(chapter_id, member, type, payload) do
    append_multi!(chapter_id, [member], type, payload)
  end

  defp append_multi!(chapter_id, actors, type, payload) do
    {:ok, envelope} =
      Envelope.new(%{
        chapter_id: chapter_id,
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
