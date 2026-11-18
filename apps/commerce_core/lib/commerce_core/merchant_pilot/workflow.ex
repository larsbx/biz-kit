defmodule CommerceCore.MerchantPilot.Workflow do
  @moduledoc """
  Pure request-to-fulfillment admission kernel for a single cooperative.

  This module does not persist, authenticate a browser, verify external evidence,
  or move money. The caller MUST derive `trusted` from current signed authority
  and run this decision inside the canonical Log's serialized admission path.
  A preflight call followed by an unconditional append is not sufficient.

  Commands have exactly `id`, `expected_version`, `action`, and `attrs`.
  Trusted scope and actor identity never come from those attributes. Evidence
  references are opaque private-record handles, not public URLs or raw documents.
  """

  @actions [:request, :qualify, :quote, :accept, :fulfill, :cancel, :dispute, :payment_evidence]
  @terminal [:fulfilled, :cancelled, :disputed]

  def actions, do: @actions

  @doc "Returns {:ok, next, :accepted | :duplicate} or {:error, reason}."
  def apply_command(state, trusted, command) do
    with :ok <- authority(state, trusted),
         :ok <- command_shape(command) do
      case receipt(state, command.id) do
        %{command: ^command} -> {:ok, state, :duplicate}
        %{} -> {:error, :idempotency_conflict}
        nil -> execute(state, trusted, command)
      end
    end
  end

  defp authority(state, t) when is_map(t) do
    required = [:chapter_id, :cooperative_id, :request_id, :actor_id]

    cond do
      t[:authorized] != true -> {:error, :forbidden}
      not Enum.all?(required, &text?(t[&1], 128)) -> {:error, :invalid_authority}
      not (is_integer(t[:now_ms]) and t.now_ms >= 0) -> {:error, :invalid_authority}
      state == nil -> :ok
      not is_map(state) -> {:error, :invalid_state}
      state.scope != {t.chapter_id, t.cooperative_id, t.request_id} -> {:error, :scope_mismatch}
      true -> :ok
    end
  end

  defp authority(_, _), do: {:error, :forbidden}

  defp command_shape(%{id: id, expected_version: v, action: a, attrs: p} = c) do
    if map_size(c) == 4 and text?(id, 128) and is_integer(v) and v >= 0 and
         a in @actions and is_map(p),
      do: :ok,
      else: {:error, :invalid_command}
  end

  defp command_shape(_), do: {:error, :invalid_command}
  defp receipt(nil, _), do: nil
  defp receipt(state, id), do: Map.get(state.receipts, id)
  defp version(nil), do: 0
  defp version(state), do: state.version

  defp execute(state, t, c) do
    if c.expected_version != version(state) do
      {:error, :stale_version}
    else
      with {:ok, next} <- transition(state, t, c.action, c.attrs) do
        record = %{command: c, actor_id: t.actor_id, at_ms: t.now_ms}
        next = %{next | version: version(state) + 1, receipts: Map.put(next.receipts, c.id, record)}
        {:ok, next, :accepted}
      end
    end
  end

  defp transition(nil, t, :request, p) do
    fields = [:buyer_business_id, :description, :quantity, :currency, :needed_by_ms, :consent_ref]

    if keys?(p, fields) and text?(p.buyer_business_id, 128) and text?(p.description, 2000) and
         is_integer(p.quantity) and p.quantity > 0 and currency?(p.currency) and
         is_integer(p.needed_by_ms) and p.needed_by_ms > t.now_ms and text?(p.consent_ref, 256) do
      {:ok, %{scope: {t.chapter_id, t.cooperative_id, t.request_id}, request: p,
        phase: :requested, version: 0, quotes: %{}, accepted_quote: nil,
        acceptance_ref: nil, outcome_ref: nil, payment_evidence: [], receipts: %{}}}
    else
      {:error, :invalid_request}
    end
  end

  defp transition(nil, _, _, _), do: {:error, :request_missing}
  defp transition(_, _, :request, _), do: {:error, :request_exists}

  defp transition(%{phase: :requested} = s, _, :qualify, p) do
    if keys?(p, [:evidence_ref]) and text?(p.evidence_ref, 256),
      do: {:ok, %{s | phase: :qualified, outcome_ref: p.evidence_ref}},
      else: {:error, :invalid_evidence}
  end

  defp transition(%{phase: :qualified} = s, t, :quote, p) do
    fields = [:quote_id, :merchant_business_id, :revision, :total_minor, :currency,
      :expires_at_ms, :source_ref]
    old = Map.get(s.quotes, p[:quote_id])

    cond do
      not (keys?(p, fields) and text?(p.quote_id, 128) and
        text?(p.merchant_business_id, 128) and is_integer(p.revision) and p.revision > 0 and
        is_integer(p.total_minor) and p.total_minor >= 0 and p.total_minor <= 9_007_199_254_740_991 and
        p.currency == s.request.currency and is_integer(p.expires_at_ms) and
        p.expires_at_ms > t.now_ms and text?(p.source_ref, 256)) -> {:error, :invalid_quote}
      p.merchant_business_id == s.request.buyer_business_id -> {:error, :same_business}
      old != nil and old.merchant_business_id != p.merchant_business_id -> {:error, :quote_owner_mismatch}
      p.revision != if(old == nil, do: 1, else: old.revision + 1) -> {:error, :quote_revision_conflict}
      true -> {:ok, %{s | quotes: Map.put(s.quotes, p.quote_id, p)}}
    end
  end

  defp transition(%{phase: :qualified, accepted_quote: nil} = s, t, :accept, p) do
    fields = [:quote_id, :revision, :buyer_business_id, :evidence_ref]
    quote = Map.get(s.quotes, p[:quote_id])

    cond do
      not (keys?(p, fields) and text?(p.evidence_ref, 256)) -> {:error, :invalid_acceptance}
      p.buyer_business_id != s.request.buyer_business_id -> {:error, :buyer_mismatch}
      quote == nil -> {:error, :quote_missing}
      p.revision != quote.revision -> {:error, :quote_revision_conflict}
      quote.expires_at_ms <= t.now_ms -> {:error, :quote_expired}
      true -> {:ok, %{s | phase: :accepted, accepted_quote: quote, acceptance_ref: p.evidence_ref}}
    end
  end

  defp transition(%{phase: :accepted} = s, _, :fulfill, p),
    do: outcome(s, :fulfilled, p)

  defp transition(%{phase: phase} = s, _, :cancel, p) when phase not in @terminal,
    do: outcome(s, :cancelled, p)

  defp transition(%{phase: phase} = s, _, :dispute, p) when phase in [:accepted, :fulfilled],
    do: outcome(s, :disputed, p)

  defp transition(%{phase: phase, accepted_quote: quote} = s, t, :payment_evidence, p)
       when phase in [:accepted, :fulfilled, :disputed] and not is_nil(quote) do
    if keys?(p, [:evidence_ref]) and text?(p.evidence_ref, 256) do
      evidence = %{reference: p.evidence_ref, recorded_by: t.actor_id, recorded_at_ms: t.now_ms,
        status: :operator_attestation, bank_verified: false}
      {:ok, %{s | payment_evidence: s.payment_evidence ++ [evidence]}}
    else
      {:error, :invalid_evidence}
    end
  end

  defp transition(_, _, _, _), do: {:error, :illegal_transition}

  defp outcome(s, phase, p) do
    if keys?(p, [:evidence_ref]) and text?(p.evidence_ref, 256),
      do: {:ok, %{s | phase: phase, outcome_ref: p.evidence_ref}},
      else: {:error, :invalid_evidence}
  end

  defp keys?(p, fields), do: Enum.sort(Map.keys(p)) == Enum.sort(fields)
  defp text?(v, max), do: is_binary(v) and String.valid?(v) and byte_size(v) in 1..max and String.trim(v) != ""
  defp currency?(v), do: is_binary(v) and Regex.match?(~r/\A[A-Z]{3}\z/, v)
end
