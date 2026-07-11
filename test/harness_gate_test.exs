defmodule CoopSubstrate.HarnessGateTest do
  @moduledoc """
  Phase 2A (docs/phase2a_plan.md P1–P7) over the real log: the harness event
  substrate. Consent is the interviewee's own signature and revocation is
  terminal + atomically excluding; corroboration requires k independent
  consent-active sources; gate(D) is a pure, as-of-reproducible fold that
  fails closed on undeclared constants; BuildStarted is unrepresentable
  until the gate holds; voice_agent mode is structurally absent.
  """

  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.Harness
  alias CoopSubstrate.Log

  @chapter "chapter-genesis"

  setup do
    %{
      steward: new_member("steward"),
      author: new_member("author"),
      gov: new_member("governance"),
      alice: new_member("interviewee"),
      bob: new_member("interviewee")
    }
  end

  # -- builders ----------------------------------------------------------------

  defp consent(actor, ref, attrs \\ []) do
    payload =
      Map.merge(
        %{
          "interviewee_ref" => ref,
          "pubkey" => {:bytes, actor.signer.pubkey},
          "key_id" => actor.signer.key_id,
          "classes" => ["synthesis", "anonymized_fixtures", "prospect_record"],
          "recording" => true
        },
        Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
      )

    signed_event(actor, "InterviewConsentGranted", payload)
  end

  defp revoke(actor, ref) do
    signed_event(actor, "InterviewConsentRevoked", %{"interviewee_ref" => ref})
  end

  defp interview(steward, id, ref, attrs \\ []) do
    payload =
      Map.merge(
        %{"section" => "D", "interview_id" => id, "interviewee_ref" => ref, "mode" => "form"},
        Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
      )

    signed_event(steward, "InterviewConducted", payload)
  end

  defp finding(steward, id, interview_ref, attrs \\ []) do
    payload =
      Map.merge(
        %{
          "finding_id" => id,
          "interview_ref" => interview_ref,
          "kind" => "process_step",
          "body" => "tenders arrive by email, accepted by gut feel before 06:00"
        },
        Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
      )

    signed_event(steward, "FindingExtracted", payload)
  end

  defp declare_constants!(author, overrides \\ %{}) do
    defaults = %{"harness/D/n" => 2, "harness/D/c" => 1, "harness/D/d" => 1, "k" => 2}

    for {name, value} <- Map.merge(defaults, overrides) do
      {:ok, _} =
        Log.append(
          signed_event(author, "CharterConstantDeclared", %{"name" => name, "value" => value})
        )
    end
  end

  defp assert_rejected(envelope, expected_reason) do
    before_head = Log.head()
    assert {:error, {:reject, _i, reason}} = Log.append(envelope)
    assert reason == expected_reason
    assert Log.head() == before_head
    assert :ok = Log.verify_chains()
  end

  # -- consent machine ----------------------------------------------------------

  test "consent is self-signed; one grant per ref; revocation is key-checked and terminal",
       ctx do
    # Not self-signed: alice signs but declares bob's key.
    assert_rejected(
      consent(ctx.alice, "IV-1", pubkey: {:bytes, ctx.bob.signer.pubkey}),
      :consent_must_be_self_signed
    )

    assert_rejected(
      consent(ctx.alice, "IV-1", classes: ["synthesis", "surveillance"]),
      {:unknown_consent_classes, ["synthesis", "surveillance"]}
    )

    {:ok, _} = Log.append(consent(ctx.alice, "IV-1"))
    assert_rejected(consent(ctx.alice, "IV-1"), {:consent_already_recorded, "IV-1"})

    # Revocation by a foreign key is rejected; by the consent key, accepted;
    # twice, rejected (terminal).
    assert_rejected(
      revoke(ctx.bob, "IV-1"),
      {:wrong_key_for_role, "interviewee", ctx.bob.signer.key_id}
    )

    {:ok, _} = Log.append(revoke(ctx.alice, "IV-1"))
    assert_rejected(revoke(ctx.alice, "IV-1"), :consent_not_active)

    # Terminal: the same ref can never be re-granted.
    assert_rejected(consent(ctx.alice, "IV-1"), {:consent_already_recorded, "IV-1"})
  end

  test "sourcing requires active consent; voice_agent is unrepresentable", ctx do
    assert_rejected(
      interview(ctx.steward, "I-1", "IV-1"),
      {:no_active_consent, "IV-1"}
    )

    {:ok, _} = Log.append(consent(ctx.alice, "IV-1"))

    assert_rejected(
      interview(ctx.steward, "I-1", "IV-1", mode: "voice_agent"),
      {:unknown_interview_mode, "voice_agent"}
    )

    {:ok, _} = Log.append(interview(ctx.steward, "I-1", "IV-1"))
    {:ok, _} = Log.append(finding(ctx.steward, "F-1", "I-1"))

    assert_rejected(
      finding(ctx.steward, "F-x", "I-1", kind: "vibe"),
      {:unknown_finding_kind, "vibe"}
    )

    # Post-revocation sourcing is unrepresentable at append.
    {:ok, _} = Log.append(revoke(ctx.alice, "IV-1"))
    assert_rejected(finding(ctx.steward, "F-2", "I-1"), {:no_active_consent, "IV-1"})

    assert_rejected(
      signed_event(ctx.steward, "DocumentCollected", %{
        "document_id" => "D-1",
        "interview_ref" => "I-1",
        "doc_kind" => "rate_confirmation",
        "artifact_hash" => {:bytes, :crypto.strong_rand_bytes(32)}
      }),
      {:no_active_consent, "IV-1"}
    )
  end

  test "corroboration requires k independent, consent-active sources", ctx do
    declare_constants!(ctx.author)
    {:ok, _} = Log.append(consent(ctx.alice, "IV-1"))
    {:ok, _} = Log.append(consent(ctx.bob, "IV-2"))
    {:ok, _} = Log.append(interview(ctx.steward, "I-1", "IV-1"))
    {:ok, _} = Log.append(interview(ctx.steward, "I-2", "IV-2"))
    {:ok, _} = Log.append(finding(ctx.steward, "F-1", "I-1"))
    {:ok, _} = Log.append(finding(ctx.steward, "F-1b", "I-1"))
    {:ok, _} = Log.append(finding(ctx.steward, "F-2", "I-2"))

    corroborate = fn claim, refs ->
      signed_event(ctx.steward, "Corroborated", %{"claim_ref" => claim, "finding_refs" => refs})
    end

    # Two findings, ONE interviewee: not independent (k = 2).
    assert_rejected(corroborate.("C-1", ["F-1", "F-1b"]), {:not_independent, 1, 2})
    assert_rejected(corroborate.("C-1", ["F-1", "F-404"]), :unknown_finding)

    {:ok, _} = Log.append(corroborate.("C-1", ["F-1", "F-2"]))
    assert_rejected(corroborate.("C-1", ["F-1", "F-2"]), {:already_corroborated, "C-1"})
  end

  test "instrument versions are monotonic; adoption requires a compiled model", ctx do
    publish = fn version ->
      signed_event(ctx.steward, "InstrumentVersionPublished", %{
        "section" => "D",
        "version" => version,
        "tree_hash" => {:bytes, :crypto.strong_rand_bytes(32)}
      })
    end

    assert_rejected(publish.(2), {:nonmonotonic_instrument_version, 2, 1})
    {:ok, _} = Log.append(publish.(1))
    {:ok, _} = Log.append(publish.(2))

    adopt =
      signed_event(ctx.gov, "SpecAdopted", %{
        "section" => "D",
        "spec_hash" => {:bytes, :crypto.strong_rand_bytes(32)},
        "envelope_defaults_hash" => {:bytes, :crypto.strong_rand_bytes(32)},
        "model_hash" => {:bytes, :crypto.strong_rand_bytes(32)}
      })

    assert_rejected(adopt, {:nothing_compiled, "D"})
  end

  # -- the gate, end to end -----------------------------------------------------

  test "gate(D): fails closed undeclared; true on the synthetic run; revocation flips it",
       ctx do
    assert {:error, :constants_undeclared} = Harness.gate(@chapter, "D")

    assert_rejected(
      signed_event(ctx.steward, "BuildStarted", %{"section" => "D"}),
      :constants_undeclared
    )

    declare_constants!(ctx.author)
    assert {:ok, false} = Harness.gate(@chapter, "D")

    # n_D = 2 interviews, k = 2 corroboration, c_D = 1 claim, d_D = 1 document.
    {:ok, _} = Log.append(consent(ctx.alice, "IV-1"))
    {:ok, _} = Log.append(consent(ctx.bob, "IV-2"))
    {:ok, _} = Log.append(interview(ctx.steward, "I-1", "IV-1"))
    {:ok, _} = Log.append(interview(ctx.steward, "I-2", "IV-2", mode: "chat"))
    {:ok, _} = Log.append(finding(ctx.steward, "F-1", "I-1"))
    {:ok, _} = Log.append(finding(ctx.steward, "F-2", "I-2"))

    {:ok, _} =
      Log.append(
        signed_event(ctx.steward, "Corroborated", %{
          "claim_ref" => "C-1",
          "finding_refs" => ["F-1", "F-2"]
        })
      )

    {:ok, _} =
      Log.append(
        signed_event(ctx.steward, "DocumentCollected", %{
          "document_id" => "D-1",
          "interview_ref" => "I-1",
          "doc_kind" => "rate_confirmation",
          "artifact_hash" => {:bytes, :crypto.strong_rand_bytes(32)}
        })
      )

    # Still short: nothing compiled/adopted/published.
    assert_rejected(
      signed_event(ctx.steward, "BuildStarted", %{"section" => "D"}),
      {:harness_gate_not_passed, "D"}
    )

    model_hash = :crypto.strong_rand_bytes(32)

    {:ok, _} =
      Log.append(
        signed_event(ctx.steward, "ProcessModelCompiled", %{
          "section" => "D",
          "artifact_hash" => {:bytes, model_hash}
        })
      )

    # Adoption binds the LATEST compiled model (2C).
    assert_rejected(
      signed_event(ctx.gov, "SpecAdopted", %{
        "section" => "D",
        "spec_hash" => {:bytes, :crypto.strong_rand_bytes(32)},
        "envelope_defaults_hash" => {:bytes, :crypto.strong_rand_bytes(32)},
        "model_hash" => {:bytes, :crypto.strong_rand_bytes(32)}
      }),
      {:model_hash_mismatch, "D"}
    )

    {:ok, _} =
      Log.append(
        signed_event(ctx.gov, "SpecAdopted", %{
          "section" => "D",
          "spec_hash" => {:bytes, :crypto.strong_rand_bytes(32)},
          "envelope_defaults_hash" => {:bytes, :crypto.strong_rand_bytes(32)},
          "model_hash" => {:bytes, model_hash}
        })
      )

    # Fixtures citing a source without the anonymized_fixtures class fail.
    carol = new_member("interviewee")
    {:ok, _} = Log.append(consent(carol, "IV-3", classes: ["synthesis"]))
    {:ok, _} = Log.append(interview(ctx.steward, "I-3", "IV-3"))

    assert_rejected(
      signed_event(ctx.steward, "FixtureSetPublished", %{
        "section" => "D",
        "fixture_hash" => {:bytes, :crypto.strong_rand_bytes(32)},
        "source_refs" => ["I-1", "I-3"]
      }),
      {:fixture_consent_missing, "IV-3"}
    )

    {:ok, [fixture_env]} =
      Log.append(
        signed_event(ctx.steward, "FixtureSetPublished", %{
          "section" => "D",
          "fixture_hash" => {:bytes, :crypto.strong_rand_bytes(32)},
          "source_refs" => ["I-1", "I-2"]
        })
      )

    assert {:ok, true} = Harness.gate(@chapter, "D")

    assert {:ok, %{interviews: 3, corroborated: 1, documents: 1, adopted: true, fixtures: true}} =
             Harness.counts(@chapter, "D")

    {:ok, _} = Log.append(signed_event(ctx.steward, "BuildStarted", %{"section" => "D"}))

    # Revoking a load-bearing source flips the gate: interviews 3→2 holds,
    # but the only corroborated claim loses independence (1 < k).
    {:ok, _} = Log.append(revoke(ctx.alice, "IV-1"))

    assert {:ok, false} = Harness.gate(@chapter, "D")
    assert {:ok, %{interviews: 2, corroborated: 0, documents: 0}} = Harness.counts(@chapter, "D")

    assert_rejected(
      signed_event(ctx.steward, "BuildStarted", %{"section" => "D", "ref" => "again"}),
      {:harness_gate_not_passed, "D"}
    )

    # As-of: the pre-revocation verdict is reproducible forever.
    assert {:ok, true} = Harness.gate(@chapter, "D", as_of: fixture_env.global_seq)
    assert :ok = Log.verify_chains()
  end
end
