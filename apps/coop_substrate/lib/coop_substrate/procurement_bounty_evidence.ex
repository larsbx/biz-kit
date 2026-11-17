defmodule CoopSubstrate.ProcurementBountyEvidence do
  @moduledoc false

  @purposes %{
    "closeout" => :confirm_bounty,
    "external_payment" => :bounty_payment_evidence
  }

  # The scope and request version identify one immutable request state in Log,
  # including the terms, selected quote revision, delivery, and any closeout.
  def attest(state, key, payload, event_id, now) do
    row = state.requests[key]
    reference = payload["evidence_ref"]
    expires = payload["expires_at_ms"]

    with {:ok, action} <- purpose(payload["purpose"]),
         :ok <- version(row, payload["expected_version"]),
         :ok <- admissible(row, action),
         :ok <- validate_reference(row, reference),
         true <- expires > now or {:error, :bounty_attestation_expired},
         {:ok, enrollment} <- enrollment(state, row) do
      attestation = %{
        scope: key,
        version: row.version,
        action: action,
        reference: reference,
        issued_at_ms: now,
        expires_at_ms: expires,
        enrollment: enrollment
      }

      {:ok, put_in(state.bounty_attestations[event_id], attestation)}
    end
  end

  def resolve(state, %{scope: scope} = row, %{action: action} = command, now, _signed_at)
      when action in [:confirm_bounty, :bounty_payment_evidence] do
    with :ok <- version(row, command.expected_version),
         :ok <- admissible(row, action),
         {:ok, current} <- enrollment(state, row),
         %{scope: ^scope, action: ^action} = attestation <-
           state.bounty_attestations[command.attrs.attestation_id],
         :ok <- current_attestation(attestation, row.version, current, now) do
      {:ok, %{command | attrs: %{evidence_ref: attestation.reference}}}
    else
      {:error, _} = error -> error
      _ -> {:error, :bounty_attestation_scope_or_purpose_mismatch}
    end
  end

  # Manual command timestamps are rounded to seconds. If admission crosses a
  # subsecond cutoff in that same second, refuse the ambiguous fulfillment.
  def resolve(
        _state,
        %{phase: :accepted, bounty: %{award: %{}}, request: %{needed_by_ms: deadline}},
        %{action: :fulfill, attrs: %{evidence_ref: reference}} = command,
        now,
        signed_at
      ) do
    cond do
      not private_reference?(reference) -> {:error, :invalid_bounty_delivery_reference}
      signed_at < deadline and now >= deadline -> {:error, :bounty_delivery_time_ambiguous}
      true -> {:ok, command}
    end
  end

  def resolve(_state, _row, %{action: action}, _now, _signed_at)
      when action in [:confirm_bounty, :bounty_payment_evidence],
      do: {:error, :request_missing}

  def resolve(_state, _row, command, _now, _signed_at), do: {:ok, command}

  def claim(state, %{bounty: %{award: award}} = row, :confirm_bounty),
    do: claim_references(state, row.scope, [award.delivery_ref, award.closeout_ref])

  def claim(state, %{bounty: %{award: award}} = row, :bounty_payment_evidence),
    do: claim_references(state, row.scope, [award.payment_ref])

  def claim(state, _row, _action), do: {:ok, state}

  defp claim_references(state, {chapter, cooperative, _}, references) do
    keys = MapSet.new(references, &{chapter, cooperative, &1})

    if MapSet.size(keys) == length(references) and MapSet.disjoint?(state.bounty_evidence, keys),
      do: {:ok, %{state | bounty_evidence: MapSet.union(state.bounty_evidence, keys)}},
      else: {:error, :bounty_evidence_already_used}
  end

  defp purpose(value) do
    case Map.fetch(@purposes, value) do
      :error -> {:error, :invalid_bounty_attestation_purpose}
      result -> result
    end
  end

  defp version(nil, _), do: {:error, :request_missing}
  defp version(%{version: version}, version), do: :ok
  defp version(_, _), do: {:error, :stale_version}

  defp admissible(%{phase: phase}, _) when phase != :fulfilled,
    do: {:error, :illegal_transition}

  defp admissible(
         %{bounty: %{award: %{delivered_on_time: true, closeout_ref: nil}}},
         :confirm_bounty
       ),
       do: :ok

  defp admissible(
         %{bounty: %{award: %{closeout_ref: closeout, payment_ref: nil}}},
         :bounty_payment_evidence
       )
       when is_binary(closeout),
       do: :ok

  defp admissible(_, _), do: {:error, :bounty_result_not_admissible}

  defp enrollment(state, %{scope: {chapter, cooperative, _}} = row) do
    ids = [
      row.request.buyer_business_id,
      row.accepted_quote.merchant_business_id,
      row.bounty.award.sourcing_business_id
    ]

    case Enum.map(ids, &state.businesses[{chapter, cooperative, &1}]) do
      [
        %{active: true, version: buyer},
        %{active: true, version: supplier},
        %{active: true, version: source}
      ] ->
        {:ok, {buyer, supplier, source}}

      _ ->
        {:error, :business_not_enrolled}
    end
  end

  defp current_attestation(attestation, version, enrollment, now) do
    cond do
      attestation.version != version -> {:error, :stale_bounty_attestation}
      attestation.enrollment != enrollment -> {:error, :stale_bounty_attestation}
      now < attestation.issued_at_ms -> {:error, :stale_bounty_attestation}
      now >= attestation.expires_at_ms -> {:error, :bounty_attestation_expired}
      true -> :ok
    end
  end

  defp validate_reference(row, reference) do
    prior_references = [
      row.request.consent_ref,
      row.bounty.terms_ref,
      row.acceptance_ref,
      row.accepted_quote.source_ref,
      row.accepted_quote.sourcing_ref,
      row.bounty.award.delivery_ref,
      row.bounty.award.closeout_ref
    ]

    cond do
      not private_reference?(reference) -> {:error, :invalid_bounty_attestation_reference}
      reference in prior_references -> {:error, :bounty_evidence_already_used}
      true -> :ok
    end
  end

  defp private_reference?(reference) do
    is_binary(reference) and String.valid?(reference) and byte_size(reference) in 1..256 and
      String.trim(reference) == reference and not String.starts_with?(reference, "dispatch:")
  end
end
