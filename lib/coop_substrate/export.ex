defmodule CoopSubstrate.Export do
  @moduledoc """
  Phase 6B (docs/phase6b_plan.md): the member-departure export workflow —
  hand-off §4a "what is exported to a member when they leave? (their own
  data, portable)"; 08 §1 signed per-owner log export as the
  external-evidence path. A bundle is the member's own streams plus the
  chapter rule streams needed to reproduce derived state, as raw canonical
  records; `verify/1` checks it offline with no store access.

  Stream membership is decided by the type registry's stream keying
  (member-keyed types whose payload names this member), never by
  string-parsing stream ids. Bilateral `obligations/*` pair streams are
  deliberately absent — counterparty policy, not mechanism (plan §deferred).
  """

  alias CoopSubstrate.Canonical
  alias CoopSubstrate.Crypto
  alias CoopSubstrate.Log
  alias CoopSubstrate.Protocol.Envelope
  alias CoopSubstrate.Protocol.StreamRoot
  alias CoopSubstrate.Protocol.TypeRegistry

  # Chapter-scoped commons streams a member needs to re-derive their own
  # balances/values/floor verdicts from the bundle alone (SUBSTRATE.md §7).
  @rule_streams ~w(accrual_rules throughput_rules floor_rules)

  @type bundle :: %{
          chapter_id: String.t(),
          member_id: String.t(),
          streams: %{optional(String.t()) => [binary()]}
        }

  @doc """
  The member's portable departure bundle: every stream keyed by this
  `member_id` in this chapter, plus the chapter's rule streams (empty rule
  streams are omitted — nothing was ever activated there).
  """
  @spec member_bundle(String.t(), String.t()) :: {:ok, bundle()} | {:error, term()}
  def member_bundle(chapter_id, member_id)
      when is_binary(chapter_id) and is_binary(member_id) do
    with {:ok, envelopes} <- Log.read_all() do
      member_streams =
        for env <- envelopes,
            env.chapter_id == chapter_id,
            member_keyed?(env.type),
            env.payload["member_id"] == member_id,
            uniq: true,
            do: env.stream_id

      rule_streams = Enum.map(@rule_streams, &(chapter_id <> "/" <> &1))

      (member_streams ++ rule_streams)
      |> Enum.reduce_while({:ok, %{}}, fn stream_id, {:ok, acc} ->
        case Log.export_stream(stream_id) do
          {:ok, []} -> {:cont, {:ok, acc}}
          {:ok, records} -> {:cont, {:ok, Map.put(acc, stream_id, records)}}
          {:error, reason} -> {:halt, {:error, {:export_failed, stream_id, reason}}}
        end
      end)
      |> case do
        {:ok, streams} ->
          {:ok, %{chapter_id: chapter_id, member_id: member_id, streams: streams}}

        error ->
          error
      end
    end
  end

  @doc """
  Offline verification of a bundle — no store access: each stream passes
  the full `Log.verify_export/1` discipline (strict decode, signatures,
  per-stream chain). Returns the decoded envelopes per stream.
  """
  @spec verify(bundle()) ::
          {:ok, %{optional(String.t()) => [CoopSubstrate.Protocol.Envelope.t()]}}
          | {:error, term()}
  def verify(%{streams: streams}) when is_map(streams) do
    Enum.reduce_while(streams, {:ok, %{}}, fn {stream_id, records}, {:ok, acc} ->
      case Log.verify_export(records) do
        {:ok, envelopes} -> {:cont, {:ok, Map.put(acc, stream_id, envelopes)}}
        {:error, reason} -> {:halt, {:error, {:stream_invalid, stream_id, reason}}}
      end
    end)
  end

  def verify(_other), do: {:error, :not_a_bundle}

  @doc """
  Anchor a bundle at a `CheckpointV2` (12A, docs/phase12a_plan.md): attach
  the checkpoint blob and one stream-heads inclusion proof per bundle
  stream. Store-side (consults the ledger for the heads); the bundle must
  describe the checkpoint's position exactly — anchor at export time.
  Proofs carry sibling hashes only, never other streams' ids.
  """
  @spec anchor(bundle(), binary()) :: {:ok, map()} | {:error, term()}
  def anchor(%{chapter_id: chapter_id, streams: streams} = bundle, checkpoint_blob) do
    with {:ok, _body, cp} <- decode_checkpoint(checkpoint_blob),
         :ok <- anchorable?(cp, chapter_id),
         {:ok, heads} <- Log.stream_heads(chapter_id, as_of: cp.global_seq),
         {:ok, proofs} <- build_proofs(streams, heads) do
      {:ok, Map.put(bundle, :anchor, %{checkpoint: checkpoint_blob, proofs: proofs})}
    end
  end

  @doc """
  Fully offline verification of an anchored bundle given only the
  chapter's checkpoint public key (distributed out-of-band, the §15.2
  doctrine): the 6B per-stream discipline, then every stream's LAST event
  hash must prove into the checkpoint's signed stream-heads root — a
  withheld tail is detectable. Returns the decoded envelopes per stream.
  """
  @spec verify_anchored(map(), binary()) :: {:ok, map()} | {:error, term()}
  def verify_anchored(
        %{streams: streams, anchor: %{checkpoint: blob, proofs: proofs}},
        checkpoint_pubkey
      ) do
    with {:ok, body, cp} <- decode_checkpoint(blob),
         :ok <- checkpoint_signed?(body, blob, checkpoint_pubkey),
         {:ok, verified} <- verify(%{streams: streams}) do
      streams
      |> Map.keys()
      |> Enum.reduce_while(:ok, fn stream_id, :ok ->
        {:ok, head} = verified[stream_id] |> List.last() |> Envelope.event_hash()

        cond do
          proofs[stream_id] == nil ->
            {:halt, {:error, {:stream_unanchored, stream_id}}}

          not StreamRoot.proven?(stream_id, head, proofs[stream_id], cp.stream_heads_root) ->
            {:halt, {:error, {:stream_head_mismatch, stream_id}}}

          true ->
            {:cont, :ok}
        end
      end)
      |> case do
        :ok -> {:ok, verified}
        error -> error
      end
    end
  end

  def verify_anchored(_bundle, _pubkey), do: {:error, :not_anchored}

  defp decode_checkpoint(blob) do
    with {:ok, %{"body" => {:bytes, body}, "signature" => {:bytes, _sig}}} <-
           Canonical.decode(blob),
         {:ok,
          %{
            "schema" => "CheckpointV2",
            "chapter_id" => chapter_id,
            "global_seq" => seq,
            "stream_heads_root" => {:bytes, root}
          }} <- Canonical.decode(body) do
      {:ok, body, %{chapter_id: chapter_id, global_seq: seq, stream_heads_root: root}}
    else
      {:ok, %{"schema" => "CheckpointV1"}} -> {:error, :checkpoint_not_anchorable}
      {:ok, _other} -> {:error, :malformed_checkpoint}
      {:error, _} = error -> error
    end
  end

  defp anchorable?(%{chapter_id: chapter_id}, chapter_id), do: :ok
  defp anchorable?(cp, _chapter_id), do: {:error, {:checkpoint_chapter_mismatch, cp.chapter_id}}

  defp checkpoint_signed?(body, blob, pubkey) do
    {:ok, %{"signature" => {:bytes, signature}}} = Canonical.decode(blob)

    if Crypto.verify(body, signature, pubkey) do
      :ok
    else
      {:error, :bad_checkpoint_signature}
    end
  end

  defp build_proofs(streams, heads) do
    Enum.reduce_while(streams, {:ok, %{}}, fn {stream_id, records}, {:ok, acc} ->
      with {:ok, envelopes} <- Log.verify_export(records),
           {:ok, head} <- envelopes |> List.last() |> Envelope.event_hash(),
           true <- heads[stream_id] == head || {:error, {:bundle_not_at_checkpoint, stream_id}},
           {:ok, proof} <- StreamRoot.prove(heads, stream_id) do
        {:cont, {:ok, Map.put(acc, stream_id, proof)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
        :error -> {:halt, {:error, {:bundle_not_at_checkpoint, stream_id}}}
      end
    end)
  end

  defp member_keyed?(type) do
    case TypeRegistry.spec(type) do
      {:ok, %{stream: {:payload_field, _prefix, "member_id"}}} -> true
      {:ok, %{stream: {:payload_fields, _prefix, fields}}} -> "member_id" in fields
      _ -> false
    end
  end
end
