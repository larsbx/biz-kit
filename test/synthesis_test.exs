defmodule CoopSubstrate.SynthesisTest do
  @moduledoc """
  Phase 2C (docs/phase2c_plan.md P1–P6): the process model recompiles
  byte-identically from the log (cherry-picking detectable); only
  synthesis-consented active sources appear; conflicts and observations
  surface verbatim; tier assignment is total and fail-closed; every spec
  node's provenance resolves in the model; adoption binds the latest model.
  """

  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.Canonical
  alias CoopSubstrate.Harness.Artifacts
  alias CoopSubstrate.Harness.Synthesis
  alias CoopSubstrate.Log

  @chapter "chapter-genesis"

  setup do
    steward = new_member("steward")
    author = new_member("author")
    alice = new_member("interviewee")
    bob = new_member("interviewee")
    carol = new_member("interviewee")

    for {name, value} <- %{"harness/D/n" => 2, "harness/D/c" => 1, "harness/D/d" => 1, "k" => 2} do
      {:ok, _} =
        Log.append(
          signed_event(author, "CharterConstantDeclared", %{"name" => name, "value" => value})
        )
    end

    grant = fn actor, ref, classes ->
      {:ok, _} =
        Log.append(
          signed_event(actor, "InterviewConsentGranted", %{
            "interviewee_ref" => ref,
            "pubkey" => {:bytes, actor.signer.pubkey},
            "key_id" => actor.signer.key_id,
            "classes" => classes,
            "recording" => false
          })
        )
    end

    grant.(alice, "IV-1", ["synthesis", "anonymized_fixtures"])
    grant.(bob, "IV-2", ["synthesis"])
    # Carol consented to prospect_record ONLY — never synthesis material.
    grant.(carol, "IV-3", ["prospect_record"])

    for {id, ref} <- [{"I-1", "IV-1"}, {"I-2", "IV-2"}, {"I-3", "IV-3"}] do
      {:ok, _} =
        Log.append(
          signed_event(steward, "InterviewConducted", %{
            "section" => "D",
            "interview_id" => id,
            "interviewee_ref" => ref,
            "mode" => "chat"
          })
        )
    end

    finding = fn id, interview, kind, body ->
      {:ok, _} =
        Log.append(
          signed_event(steward, "FindingExtracted", %{
            "finding_id" => id,
            "interview_ref" => interview,
            "kind" => kind,
            "body" => body
          })
        )
    end

    finding.("F-1", "I-1", "process_step", "tender lands by email; reply within 15 min or lose it")
    finding.("F-2", "I-2", "process_step", "email tenders, answered from the truck stop")
    finding.("F-3", "I-1", "workaround", "auto-accept anything on I-94 above $2.40/mi")
    finding.("F-4", "I-2", "exception", "driver no-showed, load re-brokered at a loss")
    finding.("F-5", "I-2", "duration", "invoice paid in 38 days")
    finding.("F-6", "I-3", "pain", "carol's finding — prospect_record consent only")

    corroborate = fn claim, refs ->
      {:ok, _} =
        Log.append(
          signed_event(steward, "Corroborated", %{"claim_ref" => claim, "finding_refs" => refs})
        )
    end

    corroborate.("C-accept", ["F-1", "F-2"])
    corroborate.("C-envelope", ["F-3", "F-2"])

    {:ok, _} =
      Log.append(
        signed_event(steward, "ConflictFlagged", %{
          "claim_ref" => "X-timing",
          "finding_refs" => ["F-1", "F-5"]
        })
      )

    %{steward: steward, gov: new_member("governance"), alice: alice}
  end

  test "the model is recompilable byte-identically; consent filters every section", ctx do
    {key_id, seed} = {ctx.steward.signer.key_id, ctx.steward.seed}

    {:ok, model} = Synthesis.compile_model(@chapter, "D")
    {:ok, model_again} = Synthesis.compile_model(@chapter, "D")
    assert model == model_again

    # Publish, fetch the artifact, recompile: byte-identical (P1).
    {:ok, %{artifact_hash: hash}} = Synthesis.publish_model(@chapter, "D", key_id, seed)
    {:ok, published_bytes} = Artifacts.get(hash)
    assert {:ok, published_bytes} == Canonical.encode(model)

    # Carol (no synthesis consent) appears NOWHERE (P2).
    refute inspect(model) =~ "F-6"
    refute inspect(model) =~ "carol"

    # Core, conflicts, observations, exceptions all surface (P3).
    assert [%{"claim_ref" => "C-accept", "sources" => 2}, %{"claim_ref" => "C-envelope"}] =
             model["core"]

    assert [%{"claim_ref" => "X-timing", "finding_refs" => ["F-1", "F-5"]}] = model["conflicts"]
    assert Enum.map(model["observations"], & &1["finding_id"]) == ["F-4", "F-5"]
    assert [%{"finding_id" => "F-4"}] = model["exceptions"]
    assert model["envelope_default_candidates"] == ["C-envelope"]

    # Revoking Alice mid-log: her material vanishes from EVERY section, and
    # C-accept drops below k=2 independent sources — out of core.
    {:ok, _} =
      Log.append(
        signed_event(ctx.alice, "InterviewConsentRevoked", %{"interviewee_ref" => "IV-1"})
      )

    {:ok, after_revocation} = Synthesis.compile_model(@chapter, "D")
    refute inspect(after_revocation) =~ "F-1"
    refute inspect(after_revocation) =~ "F-3"
    assert after_revocation["core"] == []
    assert [%{"finding_refs" => ["F-5"]}] = after_revocation["conflicts"]

    # As-of reproduces the pre-revocation model exactly (P1).
    {:ok, gate_seq} = (fn -> {:ok, Log.head().global_seq - 1} end).()
    assert {:ok, ^model} = Synthesis.compile_model(@chapter, "D", as_of: gate_seq)
  end

  test "spec: fail-closed tiers, provenance closure, adoption binds the latest model", ctx do
    {key_id, seed} = {ctx.steward.signer.key_id, ctx.steward.seed}
    {:ok, %{artifact_hash: model_hash}} = Synthesis.publish_model(@chapter, "D", key_id, seed)

    classifier = %{
      "C-accept" => %{"enveloped" => true},
      # C-envelope deliberately left unclassified.
      "C-bogus" => %{"enveloped" => true}
    }

    # Classifier hygiene: entries outside the model's core are rejected.
    assert {:error, {:classifier_unknown_claims, ["C-bogus"]}} =
             Synthesis.publish_spec(@chapter, "D", classifier)

    {:ok, %{spec_hash: spec_hash, envelope_defaults_hash: defaults_hash, model_hash: ^model_hash}} =
      Synthesis.publish_spec(@chapter, "D", Map.delete(classifier, "C-bogus"))

    {:ok, spec_bytes} = Artifacts.get(spec_hash)
    {:ok, spec} = Canonical.decode(spec_bytes)

    # Totality + fail-closed (P4): enveloped ⇒ A, unclassified ⇒ block.
    assert [
             %{"claim_ref" => "C-accept", "tier" => "A"},
             %{"claim_ref" => "C-envelope", "tier" => "block"}
           ] = spec["nodes"]

    # H-classes and contested map to R and N.
    {:ok, spec_rn} =
      Synthesis.compile_spec(
        elem(Canonical.decode(elem(Artifacts.get(model_hash), 1)), 1),
        %{"C-accept" => %{"h" => "H4"}, "C-envelope" => "contested"}
      )

    assert [%{"tier" => "R", "h_class" => "H4"}, %{"tier" => "N"}] = spec_rn["nodes"]

    # Provenance closure (P5): every node's refs resolve in the model's core.
    {:ok, model} = Synthesis.compile_model(@chapter, "D")
    core_refs = model["core"] |> Enum.flat_map(& &1["finding_refs"]) |> MapSet.new()

    for node <- spec["nodes"], ref <- node["finding_refs"] do
      assert MapSet.member?(core_refs, ref)
    end

    # Adversarial cases seed from the exception taxonomy (11 §0).
    assert [%{"finding_id" => "F-4"}] = spec["adversarial"]

    # Adoption binds the LATEST model (P6): stale hash rejected...
    adopt = fn mh ->
      signed_event(ctx.gov, "SpecAdopted", %{
        "section" => "D",
        "spec_hash" => {:bytes, spec_hash},
        "envelope_defaults_hash" => {:bytes, defaults_hash},
        "model_hash" => {:bytes, mh}
      })
    end

    assert {:error, {:reject, _, {:model_hash_mismatch, "D"}}} =
             Log.append(adopt.(:crypto.strong_rand_bytes(32)))

    {:ok, _} = Log.append(adopt.(model_hash))
    assert :ok = Log.verify_chains()
  end
end
