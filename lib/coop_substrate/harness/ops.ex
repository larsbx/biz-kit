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
  alias CoopSubstrate.Harness.Instrument
  alias CoopSubstrate.Log
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
