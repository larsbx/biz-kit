defmodule AgentOpsStore.EventEffects do
  @moduledoc """
  Pure proposal of operational effect IDs for already accepted signed events.

  This is neither a ledger parser nor permission to execute. Its caller MUST
  read a committed envelope through CoopSubstrate.Log and independently bind
  the canonical event hash to the EventCursor commit. No untrusted :pg,
  ActivityPub or agent-provided message may call this as an authority source.

  Only explicitly handled event types produce operational intents. Types
  which are intentionally irrelevant must be listed in the trusted host's
  reviewed :ignored_types allowlist. A new/unrecognized event type *stops*
  the cursor rather than losing newly relevant work by silently skipping it.

  Even agent-run-request events create only metadata for a coordinator that
  must re-check CURRENT signed read and execute grants, consent, scopes,
  profile approval and task version. This mapper launches no agents.
  """

  @segment ~r/\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\z/

  @doc "Returns a COMPLETE immutable effect descriptor list or a refusal."
  @spec derive(map(), keyword()) :: {:ok, [map()]} | {:error, atom()}
  def derive(%{type: type, event_id: id, global_seq: seq, chapter_id: chapter}, opts)
      when is_list(opts) do
    cond do
      not (is_binary(type) and segment?(id) and segment?(chapter)) ->
        {:error, :invalid_committed_event}

      not (is_integer(seq) and seq > 0) ->
        {:error, :invalid_committed_event}

      true ->
        with {:ok, ignored} <- ignored_types(opts) do
          classify(type, id, ignored)
        end
    end
  end

  def derive(_event, _opts), do: {:error, :invalid_committed_event}

  defp classify("TaskAgentRunRequestedV1", id, _ignored),
    do: {:ok, [%{effect_id: "agent-run:" <> id, kind: "agent-run-request"}]}

  defp classify("TaskAgentRunCancelledV1", id, _ignored),
    do: {:ok, [%{effect_id: "agent-reconcile:" <> id, kind: "run-cancellation"}]}

  defp classify("TaskAccessRevokedV1", id, _ignored),
    do: {:ok, [%{effect_id: "agent-reconcile:" <> id, kind: "grant-revocation"}]}

  defp classify("TaskPrincipalOffboardedV1", id, _ignored),
    do: {:ok, [%{effect_id: "agent-reconcile:" <> id, kind: "principal-offboarding"}]}

  defp classify(type, _id, ignored) do
    if MapSet.member?(ignored, type), do: {:ok, []}, else: {:error, :event_type_not_reviewed}
  end

  defp ignored_types(opts) do
    ignored = Keyword.get(opts, :ignored_types, [])

    if is_list(ignored) and Enum.all?(ignored, &segment?/1) and
         Enum.all?(
           ignored,
           &(&1 not in [
               "TaskAgentRunRequestedV1",
               "TaskAgentRunCancelledV1",
               "TaskAccessRevokedV1",
               "TaskPrincipalOffboardedV1"
             ])
         ) do
      {:ok, MapSet.new(ignored)}
    else
      {:error, :invalid_ignored_event_types}
    end
  end

  defp segment?(value), do: is_binary(value) and Regex.match?(@segment, value)
end
