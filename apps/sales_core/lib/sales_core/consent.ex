defmodule SalesCore.Consent do
  @moduledoc """
  Replayable, default-deny marketing consent and withdrawal policy.

  This is a pure policy projection, not a contact database, communications
  transport or proof of a subscriber's identity. The host must verify grants
  and consent evidence, persist events, and recheck eligibility at delivery.
  """

  @channels [:email, :sms, :phone, :push, :telegram]
  @commercial_audiences [:customer, :business_contact]

  @doc "Begin an empty tenant-scoped consent projection."
  def new(tenant) when is_binary(tenant) and byte_size(tenant) > 0 do
    {:ok, %{tenant: tenant, version: 0, entries: %{}, seen: %{}}}
  end

  def new(_), do: {:error, :invalid_tenant}

  @doc "Record an explicit grant or withdrawal at an expected revision."
  def record(state, tenant, %{id: id, expected_version: revision, op: op} = event) do
    with :ok <- scoped(state, tenant), :ok <- reference(id) do
      case Map.get(state.seen, id) do
        ^event ->
          {:ok, state, :duplicate}

        nil ->
          with :ok <- check_revision(state.version, revision),
               {:ok, updated} <- transition(state, op, event) do
            {:ok,
             %{
               updated
               | version: state.version + 1,
                 seen: Map.put(state.seen, id, event)
             }, :accepted}
          end

        _ ->
          {:error, :idempotency_conflict}
      end
    end
  end

  def record(_, _, _), do: {:error, :invalid_consent_event}

  @doc """
  True only for an explicit, current promotional grant matching party, channel,
  audience classification, jurisdiction and tenant; never for transactional
  notifications or roles inferred from authentication.
  """
  def allowed?(state, tenant, party, channel, jurisdiction, audience) do
    with :ok <- scoped(state, tenant),
         :ok <- reference(party),
         :ok <- reference(jurisdiction),
         true <- channel in @channels,
         true <- audience in @commercial_audiences do
      key = {party, channel, jurisdiction}

      case Map.get(state.entries, key) do
        %{status: :granted, audience: ^audience} -> true
        _ -> false
      end
    else
      _ -> false
    end
  end

  @doc "Rebuild the same consent projection from admitted events."
  def replay(initial, tenant, events) when is_list(events) do
    Enum.reduce_while(events, {:ok, initial}, fn event, {:ok, state} ->
      case record(state, tenant, event) do
        {:ok, next, _} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end

  def replay(_, _, _), do: {:error, :invalid_events}

  defp scoped(%{tenant: expected}, tenant) when expected == tenant, do: :ok
  defp scoped(%{tenant: _}, _), do: {:error, :wrong_tenant}
  defp scoped(_, _), do: {:error, :invalid_consent_state}
  defp check_revision(n, n), do: :ok
  defp check_revision(_, _), do: {:error, :stale_consent_version}

  defp reference(v) when is_binary(v) and byte_size(v) in 1..128, do: :ok
  defp reference(_), do: {:error, :invalid_reference}

  defp basics(event) do
    with :ok <- reference(Map.get(event, :party_ref)),
         :ok <- reference(Map.get(event, :jurisdiction)),
         true <- Map.get(event, :channel) in @channels,
         true <- is_integer(Map.get(event, :at_ms)) and event.at_ms >= 0 do
      {:ok, {event.party_ref, event.channel, event.jurisdiction}}
    else
      _ -> {:error, :invalid_consent_scope}
    end
  end

  defp newer(state, key, event) do
    case Map.get(state.entries, key) do
      nil -> :ok
      %{at_ms: timestamp} when event.at_ms > timestamp -> :ok
      _ -> {:error, :stale_consent_evidence}
    end
  end

  defp transition(state, :grant, event) do
    with {:ok, key} <- basics(event),
         true <- event[:audience] in @commercial_audiences,
         :ok <- reference(Map.get(event, :evidence_ref)),
         :ok <- newer(state, key, event),
         true <- distinct_new_evidence?(state, key, event.evidence_ref) do
      entry = %{
        status: :granted,
        audience: event.audience,
        at_ms: event.at_ms,
        evidence_ref: event.evidence_ref
      }

      {:ok, %{state | entries: Map.put(state.entries, key, entry)}}
    else
      false -> {:error, :audience_or_evidence_not_authorized}
      {:error, _} = error -> error
    end
  end

  defp transition(state, :withdraw, event) do
    with {:ok, key} <- basics(event),
         :ok <- newer(state, key, event) do
      # Withdrawing unknown consent is a suppression event, not a no-op.
      entry = %{status: :withdrawn, audience: nil, at_ms: event.at_ms, evidence_ref: nil}

      {:ok, %{state | entries: Map.put(state.entries, key, entry)}}
    end
  end

  defp transition(_, _, _), do: {:error, :unknown_consent_operation}

  defp distinct_new_evidence?(state, _key, evidence) do
    # A withdrawal replaces the current entry, but cannot make an old grant
    # receipt new again. Scan admitted history, not only the latest status.
    Enum.all?(state.seen, fn
      {_id, %{op: :grant, evidence_ref: ^evidence}} -> false
      _ -> true
    end)
  end
end
