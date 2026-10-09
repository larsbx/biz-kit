defmodule CoopSubstrate.CaptureTest do
  @moduledoc """
  Phase 2B (docs/phase2b_plan.md P3–P5): recording intake requires recording
  consent structurally; machine extraction is a proposal behind the 08 §7
  boundary — consent-gated, frontier-declaration-gated, demotable via the
  existing CorrectionRecorded with history untouched.
  """

  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.Harness
  alias CoopSubstrate.Harness.Artifacts
  alias CoopSubstrate.Log

  @chapter "chapter-genesis"

  setup do
    steward = new_member("steward")
    alice = new_member("interviewee")
    nate = new_member("interviewee")

    grant = fn actor, ref, recording ->
      {:ok, _} =
        Log.append(
          signed_event(actor, "InterviewConsentGranted", %{
            "interviewee_ref" => ref,
            "pubkey" => {:bytes, actor.signer.pubkey},
            "key_id" => actor.signer.key_id,
            "classes" => ["synthesis"],
            "recording" => recording
          })
        )
    end

    grant.(alice, "IV-1", true)
    grant.(nate, "IV-2", false)

    {:ok, _} =
      Log.append(
        signed_event(steward, "InstrumentVersionPublished", %{
          "section" => "D",
          "version" => 1,
          "tree_hash" => {:bytes, :crypto.strong_rand_bytes(32)}
        })
      )

    for {id, ref} <- [{"I-1", "IV-1"}, {"I-2", "IV-2"}] do
      {:ok, _} =
        Log.append(
          signed_event(steward, "InterviewConducted", %{
            "section" => "D",
            "interview_id" => id,
            "interviewee_ref" => ref,
            "mode" => "call",
            "instrument_version" => 1
          })
        )
    end

    %{steward: steward, alice: alice}
  end

  test "recording intake is consent-gated structurally; artifacts land out-of-log", ctx do
    {key_id, seed} = {ctx.steward.signer.key_id, ctx.steward.seed}
    audio = :crypto.strong_rand_bytes(256)

    # IV-2 granted recording: false — a recording artifact is unrepresentable.
    assert {:error, {:reject, _i, {:no_recording_consent, "IV-2"}}} =
             Harness.collect_document(@chapter, "I-2", "recording", audio, key_id, seed)

    # Non-recording documents for IV-2 are fine; recordings for IV-1 are fine.
    assert {:ok, _} =
             Harness.collect_document(@chapter, "I-2", "rate_confirmation", audio, key_id, seed)

    assert {:ok, %{artifact_hash: hash}} =
             Harness.collect_document(@chapter, "I-1", "recording", audio, key_id, seed)

    assert {:ok, ^audio} = Artifacts.get(hash)
    assert :ok = Log.verify_chains()
  end

  test "machine extraction: consent-gated proposal; frontier requires declaration; correction demotes without touching history",
       ctx do
    {:ok, hash} = Artifacts.put("transcript bytes")

    extraction = fn proposal_id, interview, model ->
      signed_event(ctx.steward, "MachineExtractionRecorded", %{
        "proposal_id" => proposal_id,
        "interview_ref" => interview,
        "artifact_hash" => {:bytes, hash},
        "model_ref" => model,
        "proposals" => [%{"kind" => "pain", "body" => "detention unpaid at receiver X"}]
      })
    end

    assert {:error, {:reject, _, {:unknown_interview, "I-404"}}} =
             Log.append(extraction.("P-0", "I-404", "self-hosted/whisper-large"))

    # Frontier model before any dated-trigger declaration: unrepresentable.
    assert {:error, {:reject, _, {:frontier_model_undeclared, "frontier:claude"}}} =
             Log.append(extraction.("P-1", "I-1", "frontier:claude"))

    # Self-hosted lands.
    {:ok, [proposal_env]} = Log.append(extraction.("P-1", "I-1", "self-hosted/whisper-large"))

    assert {:error, {:reject, _, {:proposal_already_recorded, "P-1"}}} =
             Log.append(extraction.("P-1", "I-1", "self-hosted/whisper-large"))

    # Declare the 08 §7 trigger (governance-signed); frontier becomes usable.
    gov = new_member("governance")

    {:ok, _} =
      Log.append(
        signed_event(gov, "FrontierModelUseDeclared", %{
          "purpose" => "interview transcription until self-hosted quality suffices",
          "metric" => "interviews_transcribed",
          "threshold" => 50,
          "date" => "2026-12-31"
        })
      )

    {:ok, _} = Log.append(extraction.("P-2", "I-1", "frontier:claude"))

    # Demotion: the existing correction machinery, no mutation anywhere.
    head_before = Log.head()
    {:ok, proposal_hash} = CoopSubstrate.Protocol.Envelope.event_hash(proposal_env)

    author = %{ctx.steward | signer: %{ctx.steward.signer | role: "author"}}

    {:ok, _} =
      Log.append(
        signed_event(author, "CorrectionRecorded", %{
          "target_event_hash" => {:bytes, proposal_hash},
          "reason" => "hallucinated receiver name; superseded by manual extraction"
        })
      )

    assert Log.head().global_seq == head_before.global_seq + 1

    {:ok, stream} = Log.read_stream("#{@chapter}/interviews/I-1")
    unchanged = Enum.find(stream, &(&1.event_id == proposal_env.event_id))
    assert {:ok, ^proposal_hash} = CoopSubstrate.Protocol.Envelope.event_hash(unchanged)
    assert :ok = Log.verify_chains()

    # Post-revocation extraction is unrepresentable, like every sourcing event.
    {:ok, _} =
      Log.append(signed_event(ctx.alice, "InterviewConsentRevoked", %{"interviewee_ref" => "IV-1"}))

    assert {:error, {:reject, _, {:no_active_consent, "IV-1"}}} =
             Log.append(extraction.("P-3", "I-1", "self-hosted/whisper-large"))
  end
end
