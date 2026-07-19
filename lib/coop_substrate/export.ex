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

  alias CoopSubstrate.Log
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

  defp member_keyed?(type) do
    case TypeRegistry.spec(type) do
      {:ok, %{stream: {:payload_field, _prefix, "member_id"}}} -> true
      {:ok, %{stream: {:payload_fields, _prefix, fields}}} -> "member_id" in fields
      _ -> false
    end
  end
end
