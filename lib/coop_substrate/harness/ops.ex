defmodule CoopSubstrate.Harness.Ops do
  @moduledoc """
  The operator signing core (Phase 3A; `docs/handoff_harness_ops.md`): build
  envelope → sign → append — with **zero duplicated rules**. A rejection is
  the gate's error term, returned untouched; the Mix tasks print it verbatim
  (the atoms are named for `docs/runbook_gate_d.md` phases).

  Key custody (corpus 08 §9 — day-one trusted rung, **FLAGGED temporary**;
  the upgrade path is the 1D threshold key ceremony): operator role seeds
  live as hex files under `HARNESS_KEYS_DIR` (app env `:harness_keys_dir` as
  the test fallback), `chmod 0600`. `gen_key/1` never returns a seed and
  nothing here ever prints one. Interviewee keys are the one exception BY
  PURPOSE: `consent_ceremony/3` returns the fresh seed exactly once, for
  handover — and persists nothing.
  """

  alias CoopSubstrate.Constants
  alias CoopSubstrate.Crypto
  alias CoopSubstrate.Harness
  alias CoopSubstrate.Harness.Artifacts
  alias CoopSubstrate.Harness.Fixtures
  alias CoopSubstrate.Harness.Instrument
  alias CoopSubstrate.Harness.Synthesis
  alias CoopSubstrate.Log
  alias CoopSubstrate.Projections.Membership
  alias CoopSubstrate.Protocol.Envelope

  @chapter "chapter-genesis"

  # -- key custody ---------------------------------------------------------------

  @doc "The operator key directory, or a named error — custody is explicit."
  def keys_dir do
    case System.get_env("HARNESS_KEYS_DIR") ||
           Application.get_env(:coop_substrate, :harness_keys_dir) do
      nil -> {:error, :keys_dir_unset}
      dir -> {:ok, dir}
    end
  end

  @doc "Generate a role key: 0600 hex-seed file. Returns role/key_id/path — never the seed."
  def gen_key(role) do
    with :ok <- check_role(role),
         {:ok, dir} <- keys_dir(),
         :ok <- File.mkdir_p(dir),
         path = Path.join(dir, role <> ".seed"),
         :ok <- ensure_absent(path, role) do
      {pubkey, seed} = Crypto.generate_keypair()
      File.write!(path, Base.encode16(seed, case: :lower))
      File.chmod!(path, 0o600)
      {:ok, %{role: role, key_id: key_id(pubkey), path: path}}
    end
  end

  @doc "Load a role's signer. The seed stays inside the returned struct; never print it."
  def load_signer(role) do
    with :ok <- check_role(role),
         {:ok, dir} <- keys_dir(),
         {:ok, hex} <- read_key_file(Path.join(dir, role <> ".seed"), role) do
      seed = Base.decode16!(String.trim(hex), case: :mixed)
      pubkey = Crypto.pubkey_from_seed(seed)
      {:ok, %{role: role, key_id: key_id(pubkey), pubkey: pubkey, seed: seed}}
    end
  end

  @doc "Roles with keys on disk, with their key ids (no seed material)."
  def list_keys do
    with {:ok, _dir} <- keys_dir() do
      keys =
        for role <- Constants.declarable_roles(),
            {:ok, signer} <- [load_signer(role)],
            do: %{role: role, key_id: signer.key_id}

      {:ok, keys}
    end
  end

  # -- signing core ----------------------------------------------------------------

  @doc "Append one event signed by a role key. Rejections pass through untouched."
  def append(role, type, payload) when is_binary(role) do
    with {:ok, signer} <- load_signer(role) do
      append_with([signer], type, payload)
    end
  end

  @doc "Append with explicit signers (multi-role or ephemeral, e.g. an interviewee)."
  def append_with(signers, type, payload) do
    {:ok, envelope} =
      Envelope.new(%{
        chapter_id: @chapter,
        type: type,
        payload: payload,
        signers:
          Enum.map(signers, &%{role: &1.role, pubkey: &1.pubkey, key_id: &1.key_id}),
        timestamp_ms: System.system_time(:millisecond)
      })

    signed =
      Enum.reduce(signers, envelope, fn signer, env ->
        {:ok, s} = Envelope.sign(env, signer.key_id, signer.seed)
        s
      end)

    case Log.append(signed) do
      {:ok, [env]} -> {:ok, env}
      {:error, _} = error -> error
    end
  end

  # -- ceremonies (runbook phases 0.2–0.4 and 2) ------------------------------------

  @doc """
  Runbook 0.2 in one call: generate any missing role keys, append the TOFU
  governance declaration then steward/checkpoint under it, emit a checkpoint
  to `blob_path`. Idempotent-safe: declarations the gate rejects as already
  made are reported, not retried.
  """
  def genesis(blob_path \\ "genesis_checkpoint.bin") do
    with {:ok, _} <- ensure_keys(Constants.declarable_roles()),
         {:ok, gov} <- load_signer("governance") do
      declarations =
        for role <- Constants.declarable_roles() do
          {:ok, signer} = load_signer(role)

          result =
            append_with([%{gov | role: "governance"}], "RoleKeyDeclared", %{
              "role" => role,
              "key_id" => signer.key_id,
              "pubkey" => {:bytes, signer.pubkey}
            })

          {role, elem(result, 0)}
        end

      {:ok, ck} = load_signer("checkpoint")

      with {:ok, blob} <- Log.checkpoint(@chapter, ck.key_id, ck.seed),
           :ok <- File.write(blob_path, blob) do
        {:ok, %{declared: declarations, checkpoint_path: blob_path}}
      end
    end
  end

  @doc "Runbook 0.3: the four gate constants, governance key signing as `author` (1A type)."
  def declare_constants(section, n, c, d, k) do
    with {:ok, gov} <- load_signer("governance") do
      author = %{gov | role: "author"}

      results =
        for {name, value} <- [
              {"harness/#{section}/n", n},
              {"harness/#{section}/c", c},
              {"harness/#{section}/d", d},
              {"k", k}
            ] do
          {name, append_with([author], "CharterConstantDeclared", %{"name" => name, "value" => value})}
        end

      case Enum.find(results, fn {_name, r} -> match?({:error, _}, r) end) do
        nil -> {:ok, Enum.map(results, fn {name, _} -> name end)}
        {name, error} -> {:error, {name, error}}
      end
    end
  end

  @doc """
  Runbook phase 2, the consent ceremony: ephemeral keypair, self-certified
  grant, seed RETURNED for handover — the only seed this module ever hands
  upward, and it persists nothing.
  """
  def consent_ceremony(interviewee_ref, classes, recording) do
    {pubkey, seed} = Crypto.generate_keypair()

    signer = %{role: "interviewee", key_id: key_id(pubkey), pubkey: pubkey, seed: seed}

    with {:ok, _env} <-
           append_with([signer], "InterviewConsentGranted", %{
             "interviewee_ref" => interviewee_ref,
             "pubkey" => {:bytes, pubkey},
             "key_id" => signer.key_id,
             "classes" => classes,
             "recording" => recording
           }) do
      {:ok,
       %{
         interviewee_ref: interviewee_ref,
         key_id: signer.key_id,
         seed_hex: Base.encode16(seed, case: :lower)
       }}
    end
  end

  @doc "Revocation with the seed the interviewee brings back (key_id re-derived)."
  def revoke_consent(interviewee_ref, seed_hex) do
    with {:ok, seed} <- decode_seed(seed_hex) do
      pubkey = Crypto.pubkey_from_seed(seed)

      append_with(
        [%{role: "interviewee", key_id: key_id(pubkey), pubkey: pubkey, seed: seed}],
        "InterviewConsentRevoked",
        %{"interviewee_ref" => interviewee_ref}
      )
    end
  end

  @doc "Runbook 0.4: publish an instrument tree (default: the corpus 11 §4-D seed)."
  def instrument_publish(tree \\ Instrument.seed_d()) do
    with {:ok, steward} <- load_signer("steward") do
      Instrument.publish(@chapter, tree, steward.key_id, steward.seed)
    end
  end

  # -- capture (runbook phase 3) -----------------------------------------------------

  def record_interview(interview_id, interviewee_ref, section, mode) do
    append("steward", "InterviewConducted", %{
      "section" => section,
      "interview_id" => interview_id,
      "interviewee_ref" => interviewee_ref,
      "mode" => mode
    })
  end

  def record_finding(finding_id, interview_ref, kind, body) do
    append("steward", "FindingExtracted", %{
      "finding_id" => finding_id,
      "interview_ref" => interview_ref,
      "kind" => kind,
      "body" => body
    })
  end

  @doc """
  Batch findings; each is its own signed event, so a rejection stops the
  batch AT that entry (prior events stand) and names it.
  """
  def record_findings(entries) do
    Enum.reduce_while(entries, {:ok, 0}, fn entry, {:ok, count} ->
      case record_finding(
             entry["finding_id"],
             entry["interview_ref"],
             entry["kind"],
             entry["body"]
           ) do
        {:ok, _} -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, {entry["finding_id"], reason, appended: count}}}
      end
    end)
  end

  def collect_document(interview_ref, doc_kind, binary) do
    with {:ok, steward} <- load_signer("steward") do
      Harness.collect_document(@chapter, interview_ref, doc_kind, binary, steward.key_id, steward.seed)
    end
  end

  # -- corroboration (runbook phase 4) ------------------------------------------------

  def corroborate(claim_ref, finding_refs) do
    append("steward", "Corroborated", %{"claim_ref" => claim_ref, "finding_refs" => finding_refs})
  end

  def conflict(claim_ref, finding_refs) do
    append("steward", "ConflictFlagged", %{"claim_ref" => claim_ref, "finding_refs" => finding_refs})
  end

  # -- synthesis & adoption (runbook phase 5) -----------------------------------------

  def model_publish do
    with {:ok, steward} <- load_signer("steward") do
      Synthesis.publish_model(@chapter, "D", steward.key_id, steward.seed)
    end
  end

  def model_show do
    with {:ok, state} <- Log.replay(Membership),
         hash when is_binary(hash) <-
           state.process_models[{@chapter, "D"}] || {:error, {:nothing_compiled, "D"}},
         {:ok, bytes} <- Artifacts.get(hash) do
      CoopSubstrate.Canonical.decode(bytes)
    end
  end

  def spec_publish(classifier), do: Synthesis.publish_spec(@chapter, "D", classifier)

  def adopt(spec_hash, defaults_hash, model_hash) do
    append("governance", "SpecAdopted", %{
      "section" => "D",
      "spec_hash" => {:bytes, spec_hash},
      "envelope_defaults_hash" => {:bytes, defaults_hash},
      "model_hash" => {:bytes, model_hash}
    })
  end

  # -- fixtures & funnel (runbook phase 6) --------------------------------------------

  @doc "Fixtures from a directory (every file), denylist from a lines file."
  def fixtures_publish(dir, denylist_path, source_refs) do
    with {:ok, steward} <- load_signer("steward"),
         {:ok, files} <- File.ls(dir) do
      fixtures =
        for name <- Enum.sort(files) do
          %{"name" => name, "content" => File.read!(Path.join(dir, name))}
        end

      denylist =
        denylist_path
        |> File.read!()
        |> String.split("\n", trim: true)

      Fixtures.publish(@chapter, "D", fixtures, denylist, source_refs, steward.key_id, steward.seed)
    end
  end

  def prospect(prospect_ref, interviewee_ref, interview_ref, track) do
    append("steward", "FunnelProspectEmitted", %{
      "prospect_ref" => prospect_ref,
      "interviewee_ref" => interviewee_ref,
      "interview_ref" => interview_ref,
      "track" => track
    })
  end

  def honorarium(interviewee_ref, amount_minor) do
    append("steward", "HonorariumAccrued", %{
      "interviewee_ref" => interviewee_ref,
      "amount_minor" => amount_minor
    })
  end

  # -- the R-queue (cockpit brief, Phase 5A) -------------------------------------------

  @doc "Raise a decision-ready R item (the gate enforces the shape, not this)."
  def escalate(attrs) do
    append("steward", "EscalationRaised", %{
      "item_id" => attrs["item_id"],
      "process" => attrs["process"],
      "act_type" => attrs["act_type"],
      "packet_refs" => attrs["packet_refs"],
      "recommendation" => attrs["recommendation"],
      "bounds" => attrs["bounds"],
      "compensation_path" => attrs["compensation_path"],
      "deadline_ms" => attrs["deadline_ms"],
      "basis_ref" => attrs["basis_ref"]
    })
  end

  @doc "Resolve an open item. Approval AUTHORIZES; it never executes the act."
  def decide(item_id, verdict, reason \\ nil) do
    payload = %{"item_id" => item_id, "verdict" => verdict}
    payload = if reason, do: Map.put(payload, "reason", reason), else: payload
    append("steward", "EscalationResolved", payload)
  end

  # -- the gate (runbook phase 7) ------------------------------------------------------

  def checkpoint_emit(blob_path) do
    with {:ok, ck} <- load_signer("checkpoint"),
         {:ok, blob} <- Log.checkpoint(@chapter, ck.key_id, ck.seed),
         :ok <- File.write(blob_path, blob) do
      {:ok, blob_path}
    end
  end

  def build_started(section), do: append("steward", "BuildStarted", %{"section" => section})

  @doc """
  The cockpit line (runbook phases 4 and 7): gate verdict + counts + the
  short legs NAMED in runbook terms. Presentation over the gate's own
  arithmetic — same fold, same constants, never a second judge.
  """
  def status(section) do
    with {:ok, state} <- Log.replay(Membership) do
      case Membership.harness_constants(state, @chapter, section) do
        {:error, :constants_undeclared} ->
          {:ok, %{gate: false, short: ["constants undeclared — runbook 0.3"]}}

        {:ok, constants} ->
          counts = Membership.harness_counts(state, @chapter, section, constants.k)
          {:ok, verdict} = Membership.harness_gate(state, @chapter, section)

          short =
            [
              {counts.interviews < constants.n,
               "interviews #{counts.interviews}/#{constants.n} — runbook 1-3"},
              {counts.corroborated < constants.c,
               "corroborated core #{counts.corroborated}/#{constants.c} — runbook 4"},
              {counts.documents < constants.d,
               "documents #{counts.documents}/#{constants.d} — runbook 3"},
              {not counts.adopted, "spec not adopted — runbook 5"},
              {not counts.fixtures, "fixtures not published — runbook 6"}
            ]
            |> Enum.filter(&elem(&1, 0))
            |> Enum.map(&elem(&1, 1))

          {:ok, %{gate: verdict, counts: counts, constants: constants, short: short}}
      end
    end
  end

  # -- internals ---------------------------------------------------------------------

  defp ensure_keys(roles) do
    results =
      for role <- roles do
        case gen_key(role) do
          {:ok, _} -> :ok
          {:error, {:key_exists, _}} -> :ok
          {:error, _} = error -> error
        end
      end

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> {:ok, roles}
      error -> error
    end
  end

  defp ensure_absent(path, role) do
    if File.exists?(path), do: {:error, {:key_exists, role}}, else: :ok
  end

  defp key_id(pubkey), do: "k-" <> Base.encode16(binary_part(pubkey, 0, 4), case: :lower)

  defp check_role(role) do
    if role in Constants.declarable_roles() do
      :ok
    else
      {:error, {:unknown_role, role}}
    end
  end

  defp read_key_file(path, role) do
    case File.read(path) do
      {:ok, hex} -> {:ok, hex}
      {:error, :enoent} -> {:error, {:no_key, role}}
      {:error, _} = error -> error
    end
  end

  defp decode_seed(seed_hex) do
    case Base.decode16(String.trim(seed_hex), case: :mixed) do
      {:ok, <<_::256>> = seed} -> {:ok, seed}
      _ -> {:error, :malformed_seed}
    end
  end
end
