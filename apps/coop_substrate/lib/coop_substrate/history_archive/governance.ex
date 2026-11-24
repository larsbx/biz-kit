defmodule CoopSubstrate.HistoryArchive.Governance do
  @moduledoc """
  A pure archive-to-fence selection fold over a verified canonical prefix.

  The caller MUST obtain the state with `Log.replay_verified/2`: this module
  does not verify signatures, hashes, or envelope schemas. It checks the
  historical governance-key authority for governance-key changes and archive
  and fence assertions. It does not replace the full domain admission gate.

  Authority is checked at each record's position, so later key revocation
  does not invalidate an earlier authorized archive. Genesis retains the
  existing trust-on-first-use, self-certified rule; its checkpoint still
  needs independent publication. Errors block preflight selection only and
  do not change ordinary replay of existing logs.
  """

  def init do
    %{
      global_seq: 0,
      event_ids: MapSet.new(),
      governance: %{},
      archives: %{},
      fences: %{},
      error: nil
    }
  end

  def handle_event(_env, %{error: error} = state) when not is_nil(error), do: state

  def handle_event(env, state) when is_map(env) do
    with :ok <- check_position(env, state),
         {:ok, next} <- fold_record(env, state) do
      %{next | global_seq: env.global_seq, event_ids: MapSet.put(next.event_ids, env.event_id)}
    else
      {:error, reason} ->
        %{state | error: {:governance_record_invalid, Map.get(env, :event_id), reason}}
    end
  end

  def handle_event(_env, state),
    do: %{state | error: {:governance_record_invalid, nil, :invalid_record}}

  @doc "Select one exact archive record, strictly before the first matching fence if present."
  def select(state, chapter, writer, archive_event_id, digest) do
    cond do
      state.error != nil ->
        {:error, state.error}

      not Enum.all?([chapter, writer, archive_event_id], &nonempty_string?/1) or
          not digest?(digest) ->
        {:error, :invalid_archive_selection}

      true ->
        select_archive(state, chapter, writer, archive_event_id, digest)
    end
  end

  defp select_archive(state, chapter, writer, event_id, digest) do
    archive = state.archives[event_id]
    fence = state.fences[{chapter, writer}]

    cond do
      archive == nil ->
        {:error, :archive_record_not_found}

      archive.chapter_id != chapter or archive.writer != writer ->
        {:error, :archive_record_context_mismatch}

      archive.manifest_sha256 != digest ->
        {:error, :archive_record_digest_mismatch}

      fence != nil and archive.global_seq >= fence.global_seq ->
        {:error, :archive_not_before_fence}

      true ->
        {:ok,
         %{
           archive_event_id: event_id,
           archive_global_seq: archive.global_seq,
           fence_event_id: if(fence, do: fence.event_id),
           fence_global_seq: if(fence, do: fence.global_seq)
         }}
    end
  end

  defp check_position(env, state) do
    cond do
      not nonempty_string?(Map.get(env, :event_id)) ->
        {:error, :invalid_event_id}

      MapSet.member?(state.event_ids, env.event_id) ->
        {:error, :duplicate_event_id}

      Map.get(env, :global_seq) !== state.global_seq + 1 ->
        {:error, {:unexpected_global_sequence, state.global_seq + 1, Map.get(env, :global_seq)}}

      true ->
        :ok
    end
  end

  defp fold_record(
         %{type: "RoleKeyDeclared", payload: %{"role" => "governance"}} = env,
         state
       ) do
    keys = state.governance[env.chapter_id]
    key_id = env.payload["key_id"]
    pubkey = env.payload["pubkey"]

    with :ok <- check_governance_shape(env),
         :ok <- check_key_payload(key_id, pubkey),
         :ok <- check_declaration(env, keys) do
      {:bytes, bytes} = pubkey
      declared = Map.put(keys || %{}, key_id, bytes)
      {:ok, put_in(state, [:governance, env.chapter_id], declared)}
    end
  end

  defp fold_record(
         %{type: "RoleKeyRevoked", payload: %{"role" => "governance"}} = env,
         state
       ) do
    keys = state.governance[env.chapter_id]
    key_id = env.payload["key_id"]

    with :ok <- check_governance_shape(env),
         :ok <- require_genesis(keys),
         :ok <- check_authority(env.signers, keys),
         :ok <- check_revocation(keys, key_id) do
      {:ok, put_in(state, [:governance, env.chapter_id], Map.delete(keys, key_id))}
    end
  end

  defp fold_record(%{type: type} = env, state)
       when type in ["LegacyHistoryArchived", "LegacyWriterFenced"] do
    with :ok <- check_governance_shape(env),
         :ok <- check_authority(env.signers, state.governance[env.chapter_id]),
         :ok <- check_assertion(env) do
      record = %{
        event_id: env.event_id,
        global_seq: env.global_seq,
        chapter_id: env.chapter_id,
        writer: env.payload["writer"]
      }

      case type do
        "LegacyHistoryArchived" ->
          record = Map.put(record, :manifest_sha256, env.payload["manifest_sha256"])
          {:ok, put_in(state, [:archives, env.event_id], record)}

        "LegacyWriterFenced" ->
          scope = {env.chapter_id, record.writer}
          {:ok, %{state | fences: Map.put_new(state.fences, scope, record)}}
      end
    end
  end

  defp fold_record(_env, state), do: {:ok, state}

  defp check_governance_shape(env) do
    if nonempty_string?(Map.get(env, :chapter_id)) and is_map(Map.get(env, :payload)) and
         is_list(Map.get(env, :signers)) and env.signers != [] and
         Enum.all?(env.signers, &governance_signer?/1) do
      :ok
    else
      {:error, :invalid_governance_record}
    end
  end

  defp governance_signer?(%{role: "governance", key_id: id, pubkey: key})
       when is_binary(key) and byte_size(key) == 32,
       do: nonempty_string?(id)

  defp governance_signer?(_), do: false

  defp check_key_payload(key_id, {:bytes, bytes})
       when is_binary(bytes) and byte_size(bytes) == 32 do
    if nonempty_string?(key_id), do: :ok, else: {:error, :invalid_role_key}
  end

  defp check_key_payload(_, _), do: {:error, :invalid_role_key}

  defp check_declaration(env, nil) do
    {:bytes, pubkey} = env.payload["pubkey"]

    if Enum.any?(env.signers, fn signer ->
         signer.key_id == env.payload["key_id"] and signer.pubkey == pubkey
       end) do
      :ok
    else
      {:error, :genesis_must_be_self_signed}
    end
  end

  defp check_declaration(env, keys) do
    with :ok <- check_authority(env.signers, keys) do
      if Map.has_key?(keys, env.payload["key_id"]),
        do: {:error, {:role_key_already_declared, "governance", env.payload["key_id"]}},
        else: :ok
    end
  end

  defp check_authority(_signers, nil), do: {:error, :no_governance}

  defp check_authority(signers, keys) do
    Enum.reduce_while(signers, :ok, fn signer, :ok ->
      if keys[signer.key_id] == signer.pubkey,
        do: {:cont, :ok},
        else: {:halt, {:error, {:role_key_not_declared, "governance", signer.key_id}}}
    end)
  end

  defp require_genesis(nil), do: {:error, :genesis_required}
  defp require_genesis(_keys), do: :ok

  defp check_revocation(keys, key_id) do
    cond do
      not Map.has_key?(keys, key_id) ->
        {:error, {:unknown_role_key, "governance", key_id}}

      map_size(keys) == 1 ->
        {:error, :cannot_orphan_governance}

      true ->
        :ok
    end
  end

  defp check_assertion(env) do
    cond do
      not nonempty_string?(env.payload["writer"]) ->
        {:error, :invalid_writer}

      env.type == "LegacyHistoryArchived" and not digest?(env.payload["manifest_sha256"]) ->
        {:error, :bad_manifest_digest}

      true ->
        :ok
    end
  end

  defp nonempty_string?(value), do: is_binary(value) and value != ""
  defp digest?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
end
