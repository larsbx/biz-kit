defmodule CoopSubstrate.FixturesFunnelTest do
  @moduledoc """
  Phase 2D (docs/phase2d_plan.md P1–P5): the anonymization predicate blocks
  publication (nothing persists); funnel prospects carry full provenance and
  are consent-gated; and the WHOLE pipeline — real Synthesis/Fixtures
  modules, no random hashes — drives gate(D) true end to end, with a
  revocation flipping it back (acceptance [2D]).
  """

  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.Harness
  alias CoopSubstrate.Harness.Anonymization
  alias CoopSubstrate.Harness.Fixtures
  alias CoopSubstrate.Harness.Synthesis
  alias CoopSubstrate.Log

  @chapter "chapter-genesis"

  test "the anonymization predicate: regex classes, denylist, fail-closed non-text" do
    assert Anonymization.anonymized?("carrier accepts I-94 loads above a floor rate")

    assert [{:mc_number, _}] = Anonymization.violations("their authority is MC 123456")
    assert [{:mc_number, _}] = Anonymization.violations("MC-987654 called")
    assert [{:dot_number, _}] = Anonymization.violations("USDOT 4415991 on the door")
    assert [{:email, _}] = Anonymization.violations("dispatch at ada@haulers.example handled it")
    assert [{:phone, _}] = Anonymization.violations("call 313-555-0142 for detention")

    assert [{:denylist, "Malik"}] =
             Anonymization.violations("malik runs three trucks", ["Malik"])

    assert [{:unscannable, :not_text}] = Anonymization.violations(<<0xFF, 0xFE, 0x00>>)
  end

  test "acceptance [2D]: the full pipeline on synthetic data, then revocation flips it" do
    steward = new_member("steward")
    author = new_member("author")
    gov = new_member("governance")
    alice = new_member("interviewee")
    bob = new_member("interviewee")
    {key_id, seed} = {steward.signer.key_id, steward.seed}

    for {name, value} <- %{"harness/D/n" => 2, "harness/D/c" => 1, "harness/D/d" => 1, "k" => 2} do
      {:ok, _} =
        Log.append(
          signed_event(author, "CharterConstantDeclared", %{"name" => name, "value" => value})
        )
    end

    for {actor, ref} <- [{alice, "IV-1"}, {bob, "IV-2"}] do
      {:ok, _} =
        Log.append(
          signed_event(actor, "InterviewConsentGranted", %{
            "interviewee_ref" => ref,
            "pubkey" => {:bytes, actor.signer.pubkey},
            "key_id" => actor.signer.key_id,
            "classes" => ["synthesis", "anonymized_fixtures", "prospect_record"],
            "recording" => false
          })
        )
    end

    for {id, ref} <- [{"I-1", "IV-1"}, {"I-2", "IV-2"}] do
      {:ok, _} =
        Log.append(
          signed_event(steward, "InterviewConducted", %{
            "section" => "D",
            "interview_id" => id,
            "interviewee_ref" => ref,
            "mode" => "form"
          })
        )
    end

    for {fid, iid, kind, body} <- [
          {"F-1", "I-1", "process_step", "tenders arrive by email, answered same hour"},
          {"F-2", "I-2", "process_step", "email tenders; the good brokers call first"},
          {"F-3", "I-2", "exception", "reefer died at the receiver; claim took months"}
        ] do
      {:ok, _} =
        Log.append(
          signed_event(steward, "FindingExtracted", %{
            "finding_id" => fid,
            "interview_ref" => iid,
            "kind" => kind,
            "body" => body
          })
        )
    end

    {:ok, _} =
      Log.append(
        signed_event(steward, "Corroborated", %{
          "claim_ref" => "C-1",
          "finding_refs" => ["F-1", "F-2"]
        })
      )

    {:ok, _} =
      Harness.collect_document(@chapter, "I-1", "rate_confirmation", "redacted rate con", key_id, seed)

    # Real synthesis + spec + adoption.
    {:ok, %{artifact_hash: _}} = Synthesis.publish_model(@chapter, "D", key_id, seed)

    {:ok, %{spec_hash: spec_hash, envelope_defaults_hash: defaults_hash, model_hash: model_hash}} =
      Synthesis.publish_spec(@chapter, "D", %{"C-1" => %{"enveloped" => true}})

    {:ok, _} =
      Log.append(
        signed_event(gov, "SpecAdopted", %{
          "section" => "D",
          "spec_hash" => {:bytes, spec_hash},
          "envelope_defaults_hash" => {:bytes, defaults_hash},
          "model_hash" => {:bytes, model_hash}
        })
      )

    # A violating fixture set is unpublishable — nothing persists (P1).
    head_before = Log.head()

    assert {:error, {:anonymization_violation, "rate_con_1.txt", [{:mc_number, _}]}} =
             Fixtures.publish(
               @chapter,
               "D",
               [%{"name" => "rate_con_1.txt", "content" => "carrier MC 123456 accepts..."}],
               ["Malik"],
               ["I-1"],
               key_id,
               seed
             )

    assert Log.head() == head_before

    {:ok, %{fixture_hash: _}} =
      Fixtures.publish(
        @chapter,
        "D",
        [
          %{"name" => "rate_con_1.txt", "content" => "carrier [REDACTED] accepts lane at floor"},
          %{"name" => "timeline_1.txt", "content" => "invoice paid in 38 days"}
        ],
        ["Malik"],
        ["I-1", "I-2"],
        key_id,
        seed
      )

    # Funnel: provenance-complete, consent-gated (P3).
    prospect = fn ref, ivee, interview ->
      signed_event(steward, "FunnelProspectEmitted", %{
        "prospect_ref" => ref,
        "interviewee_ref" => ivee,
        "interview_ref" => interview,
        "track" => "D"
      })
    end

    assert {:error, {:reject, _, {:interview_interviewee_mismatch, "I-2"}}} =
             Log.append(prospect.("P-1", "IV-1", "I-2"))

    {:ok, _} = Log.append(prospect.("P-1", "IV-1", "I-1"))

    assert {:error, {:reject, _, {:prospect_already_emitted, "P-1"}}} =
             Log.append(prospect.("P-1", "IV-1", "I-1"))

    # The gate is true end to end; the build marker lands (P4).
    assert {:ok, true} = Harness.gate(@chapter, "D")
    {:ok, [build_env]} = Log.append(signed_event(steward, "BuildStarted", %{"section" => "D"}))

    # Revocation flips everything: gate false, BuildStarted re-blocked,
    # further prospect emission for the revoked source unrepresentable.
    {:ok, _} =
      Log.append(signed_event(alice, "InterviewConsentRevoked", %{"interviewee_ref" => "IV-1"}))

    assert {:ok, false} = Harness.gate(@chapter, "D")

    assert {:error, {:reject, _, {:harness_gate_not_passed, "D"}}} =
             Log.append(signed_event(steward, "BuildStarted", %{"section" => "D", "ref" => "x"}))

    assert {:error, {:reject, _, {:no_active_consent, "IV-1"}}} =
             Log.append(prospect.("P-2", "IV-1", "I-1"))

    # And the pre-revocation world is reproducible forever.
    assert {:ok, true} = Harness.gate(@chapter, "D", as_of: build_env.global_seq)
    assert :ok = Log.verify_chains()
  end

  test "prospect emission requires the prospect_record class" do
    steward = new_member("steward")
    dana = new_member("interviewee")

    {:ok, _} =
      Log.append(
        signed_event(dana, "InterviewConsentGranted", %{
          "interviewee_ref" => "IV-9",
          "pubkey" => {:bytes, dana.signer.pubkey},
          "key_id" => dana.signer.key_id,
          "classes" => ["synthesis"],
          "recording" => false
        })
      )

    {:ok, _} =
      Log.append(
        signed_event(steward, "InterviewConducted", %{
          "section" => "D",
          "interview_id" => "I-9",
          "interviewee_ref" => "IV-9",
          "mode" => "call"
        })
      )

    assert {:error, {:reject, _, {:prospect_consent_missing, "IV-9"}}} =
             Log.append(
               signed_event(steward, "FunnelProspectEmitted", %{
                 "prospect_ref" => "P-9",
                 "interviewee_ref" => "IV-9",
                 "interview_ref" => "I-9",
                 "track" => "D"
               })
             )
  end
end
