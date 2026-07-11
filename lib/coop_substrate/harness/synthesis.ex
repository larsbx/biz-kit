defmodule CoopSubstrate.Harness.Synthesis do
  @moduledoc """
  Synthesis + spec compilation (Phase 2C; corpus 11 §1.3–§1.4).

  The process model is a **pure function of (log ≤ as_of, consent state)** —
  deterministically sorted, so anyone can recompile and byte-compare against
  the published artifact: selective compilation is detectable, not
  preventable-by-policy. Only `synthesis`-consented, active sources appear
  anywhere; conflicts and out-of-core observations surface verbatim (11 P4 —
  nothing is averaged away).

  The spec compiler takes a **classifier as data**: findings carry no act
  semantics, so tier assignment is the operator's explicit judgment,
  embedded in the spec artifact and reviewed at the one human signature.
  Rules (10 §0, 09 §1): `H1–H6 ⇒ R` · `contested ⇒ N` · `enveloped ⇒ A` ·
  **anything else ⇒ block** — unclassified acts fail closed, never default
  to A.
  """

  alias CoopSubstrate.Canonical
  alias CoopSubstrate.Crypto
  alias CoopSubstrate.Harness.Artifacts
  alias CoopSubstrate.Log
  alias CoopSubstrate.Projections.Membership
  alias CoopSubstrate.Protocol.Envelope

  @h_classes ~w(H1 H2 H3 H4 H5 H6)

  # -- the model ----------------------------------------------------------------

  @doc "Compile `ProcessModelV1` for a section. Pure; supports `as_of:`."
  @spec compile_model(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def compile_model(chapter_id, section, opts \\ []) do
    with {:ok, gate} <- Log.replay(Membership, opts),
         {:ok, %{k: k}} <- Membership.harness_constants(gate, chapter_id, section),
         {:ok, envelopes} <- Log.read_all(Keyword.take(opts, [:as_of])) do
      findings = eligible_findings(envelopes, gate, chapter_id, section)

      core =
        for {{^chapter_id, claim_ref}, refs} <- gate.corroborations,
            surviving = Enum.sort(Enum.filter(refs, &Map.has_key?(findings, &1))),
            sources = distinct_sources(findings, surviving),
            sources >= k do
          %{
            "claim_ref" => claim_ref,
            "finding_refs" => surviving,
            "kinds" => surviving |> Enum.map(&findings[&1]["kind"]) |> Enum.uniq() |> Enum.sort(),
            "bodies" => surviving |> Enum.map(&findings[&1]["body"]) |> Enum.sort(),
            "sources" => sources
          }
        end

      core = Enum.sort_by(core, & &1["claim_ref"])
      core_refs = core |> Enum.flat_map(& &1["finding_refs"]) |> MapSet.new()

      conflicts =
        for env <- envelopes,
            env.type == "ConflictFlagged" and env.chapter_id == chapter_id,
            surviving =
              env.payload["finding_refs"]
              |> Enum.filter(&Map.has_key?(findings, &1))
              |> Enum.sort(),
            surviving != [] do
          %{"claim_ref" => env.payload["claim_ref"], "finding_refs" => surviving}
        end

      observations =
        for {id, finding} <- Enum.sort(findings), not MapSet.member?(core_refs, id) do
          finding |> Map.delete("interviewee_ref") |> Map.put("finding_id", id)
        end

      exceptions =
        for {id, %{"kind" => "exception"} = finding} <- Enum.sort(findings) do
          %{"finding_id" => id, "body" => finding["body"]}
        end

      documents =
        envelopes
        |> Enum.filter(fn env ->
          env.type == "DocumentCollected" and env.chapter_id == chapter_id and
            eligible_interview?(gate, chapter_id, section, env.payload["interview_ref"])
        end)
        |> Enum.frequencies_by(& &1.payload["doc_kind"])
        |> Enum.sort()
        |> Enum.map(fn {kind, count} -> %{"doc_kind" => kind, "count" => count} end)

      candidates =
        for claim <- core,
            Enum.any?(claim["kinds"], &(&1 in ["workaround", "tool"])),
            do: claim["claim_ref"]

      {:ok,
       %{
         "schema" => "ProcessModelV1",
         "section" => section,
         "core" => core,
         "conflicts" => Enum.sort_by(conflicts, & &1["claim_ref"]),
         "observations" => observations,
         "exceptions" => exceptions,
         "durations" =>
           findings |> Map.values() |> Enum.filter(&(&1["kind"] == "duration"))
           |> Enum.map(& &1["body"]) |> Enum.sort(),
         "documents" => documents,
         # FLAGGED PLACEHOLDER heuristic (docs/phase2c_plan.md): candidate
         # selection is synthesis judgment, reviewed at adoption.
         "envelope_default_candidates" => candidates
       }}
    end
  end

  @doc "Compile, store the artifact, and append the gated `ProcessModelCompiled`."
  @spec publish_model(String.t(), String.t(), String.t(), <<_::256>>) ::
          {:ok, %{artifact_hash: <<_::256>>}} | {:error, term()}
  def publish_model(chapter_id, section, key_id, seed) do
    with {:ok, model} <- compile_model(chapter_id, section),
         {:ok, bytes} <- Canonical.encode(model),
         {:ok, artifact_hash} <- Artifacts.put(bytes),
         {:ok, _} <-
           append_steward(
             chapter_id,
             "ProcessModelCompiled",
             %{"section" => section, "artifact_hash" => {:bytes, artifact_hash}},
             key_id,
             seed
           ) do
      {:ok, %{artifact_hash: artifact_hash}}
    end
  end

  # -- the spec -----------------------------------------------------------------

  @doc """
  `WorkflowSpecV1` from a model + a per-claim classifier. Pure. Every node's
  provenance resolves within the model by construction; classifier entries
  for claims outside the model's core are rejected.
  """
  @spec compile_spec(map(), map()) :: {:ok, map()} | {:error, term()}
  def compile_spec(%{"schema" => "ProcessModelV1"} = model, classifier) do
    core_refs = Enum.map(model["core"], & &1["claim_ref"])

    case Map.keys(classifier) -- core_refs do
      [] ->
        nodes =
          for claim <- model["core"] do
            base = %{
              "claim_ref" => claim["claim_ref"],
              "tier" => tier(classifier[claim["claim_ref"]]),
              "finding_refs" => claim["finding_refs"]
            }

            case classifier[claim["claim_ref"]] do
              %{"h" => h} -> Map.put(base, "h_class", h)
              _ -> base
            end
          end

        {:ok,
         %{
           "schema" => "WorkflowSpecV1",
           "section" => model["section"],
           "model_hash" => {:bytes, Canonical.hash!(model)},
           "nodes" => nodes,
           "adversarial" =>
             Enum.map(model["exceptions"], &%{"case" => &1["body"], "finding_id" => &1["finding_id"]}),
           "properties" => [
             "replay-determinism: the model recompiles byte-identically from the log",
             "provenance-closure: every node's finding_refs resolve in the model",
             "fail-closed-tiers: unclassified acts are block, never A"
           ],
           "classifier" => classifier
         }}

      unknown ->
        {:error, {:classifier_unknown_claims, Enum.sort(unknown)}}
    end
  end

  def compile_spec(_model, _classifier), do: {:error, :malformed_model}

  @doc """
  Fetch the section's latest compiled model, compile the spec and the
  envelope-defaults artifact, and store both. Returns the three hashes the
  governance-signed `SpecAdopted` must carry — the adoption append itself is
  deliberately NOT wrapped (it is the human's act).
  """
  @spec publish_spec(String.t(), String.t(), map()) ::
          {:ok, %{spec_hash: binary(), envelope_defaults_hash: binary(), model_hash: binary()}}
          | {:error, term()}
  def publish_spec(chapter_id, section, classifier) do
    with {:ok, gate} <- Log.replay(Membership),
         {:ok, model_hash} <- latest_model(gate, chapter_id, section),
         {:ok, bytes} <- Artifacts.get(model_hash),
         {:ok, model} <- Canonical.decode(bytes),
         {:ok, spec} <- compile_spec(model, classifier),
         {:ok, spec_bytes} <- Canonical.encode(spec),
         {:ok, spec_hash} <- Artifacts.put(spec_bytes),
         {:ok, defaults_bytes} <-
           Canonical.encode(%{
             "schema" => "EnvelopeDefaultsV1",
             "section" => section,
             "candidates" => model["envelope_default_candidates"]
           }),
         {:ok, defaults_hash} <- Artifacts.put(defaults_bytes) do
      {:ok, %{spec_hash: spec_hash, envelope_defaults_hash: defaults_hash, model_hash: model_hash}}
    end
  end

  # -- internals ----------------------------------------------------------------

  defp tier(%{"h" => h}) when h in @h_classes, do: "R"
  defp tier("contested"), do: "N"
  defp tier(%{"enveloped" => true}), do: "A"
  defp tier(_unclassified_or_malformed), do: "block"

  defp latest_model(gate, chapter_id, section) do
    case gate.process_models[{chapter_id, section}] do
      nil -> {:error, {:nothing_compiled, section}}
      hash -> {:ok, hash}
    end
  end

  defp eligible_findings(envelopes, gate, chapter_id, section) do
    for env <- envelopes,
        env.type == "FindingExtracted" and env.chapter_id == chapter_id,
        eligible_interview?(gate, chapter_id, section, env.payload["interview_ref"]),
        into: %{} do
      interview = gate.interviews[{chapter_id, env.payload["interview_ref"]}]

      {env.payload["finding_id"],
       %{
         "kind" => env.payload["kind"],
         "body" => env.payload["body"],
         "interview_ref" => env.payload["interview_ref"],
         "interviewee_ref" => interview.interviewee_ref
       }}
    end
  end

  # Consent class covers the use (11 P2): synthesis-consented AND active.
  defp eligible_interview?(gate, chapter_id, section, interview_ref) do
    with %{section: ^section, interviewee_ref: ref} <- gate.interviews[{chapter_id, interview_ref}],
         %{active: true, classes: classes} <- gate.consents[{chapter_id, ref}] do
      "synthesis" in classes
    else
      _ -> false
    end
  end

  # Independence = distinct INTERVIEWEES, not interviews (one person's two
  # interviews are one source) — same rule as the append gate's check.
  defp distinct_sources(findings, finding_ids) do
    finding_ids
    |> Enum.map(&findings[&1]["interviewee_ref"])
    |> Enum.uniq()
    |> length()
  end

  defp append_steward(chapter_id, type, payload, key_id, seed) do
    {:ok, envelope} =
      Envelope.new(%{
        chapter_id: chapter_id,
        type: type,
        payload: payload,
        signers: [%{role: "steward", pubkey: Crypto.pubkey_from_seed(seed), key_id: key_id}],
        timestamp_ms: System.system_time(:millisecond)
      })

    {:ok, signed} = Envelope.sign(envelope, key_id, seed)
    Log.append(signed)
  end
end
