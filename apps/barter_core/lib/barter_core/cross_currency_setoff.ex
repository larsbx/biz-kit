defmodule BarterCore.CrossCurrencySetoff do
  @moduledoc """
  Pure, unsigned preview of bilateral cross-currency commercial setoff.

  A negotiated rate is an exact rational number of quote currency minor
  units per base currency minor unit. Neither a market FX quote nor a legal
  agreement is authenticated here. No currency is exchanged, no obligation is
  discharged, no business journal is posted, and no bank/Hawala instruction
  is made.

  This is a separate contract from the same-currency LedgerFirstClearing
  preview and the legacy aggregate-signed NettingExecuted event.
  """

  alias BarterCore, as: B

  @schema "bizkit.barter.cross-currency-setoff-preview.v1"
  @max_minor 9_007_199_254_740_991
  @source_keys ~w(amount_minor creditor currency debtor evidence_ref id revision status valid_until)a
  @rate_keys ~w(agreed_at agreement_ref base_currency denominator evidence_ref numerator quote_currency valid_until)a

  @doc """
  Preview the largest exact-minor-unit offset of two reciprocal claims.

  The a_to_b source is the quote-currency claim, b_to_a the base-currency
  claim. The caller supplies an exact, reduced positive rational rate:
  numerator / denominator in quote minor units per base minor unit.

  Only multiples of the denominator in base minor units can extinguish
  exactly the numerator's quote minor units. Fractional minor-unit
  settlement and implicit rounding are deliberately refused.

  All input sources and references are host assertions, NOT independently
  authenticated corporate consent, rate agreement or legal disposition.
  """
  def propose(a_to_b, b_to_a, rate, intent_id, now)
      when is_map(a_to_b) and is_map(b_to_a) and is_map(rate) and
             is_binary(intent_id) and is_integer(now) and now >= 0 do
    with :ok <- validate_sources(a_to_b, b_to_a, intent_id, now),
         :ok <- validate_rate(rate, a_to_b.currency, b_to_a.currency, now),
         {:ok, quote_cleared, base_cleared} <-
           exact_reduction(a_to_b.amount_minor, b_to_a.amount_minor, rate) do
      reduction_a = source_reduction(a_to_b, quote_cleared)
      reduction_b = source_reduction(b_to_a, base_cleared)

      totals =
        [reduction_a, reduction_b]
        |> Enum.map(fn source ->
          %{
            currency: source.currency,
            original_minor: source.original_minor,
            proposed_reduction_minor: source.proposed_reduction_minor,
            residual_minor: source.residual_minor
          }
        end)
        |> Enum.sort_by(& &1.currency)

      fields =
        [@schema, intent_id, Integer.to_string(now)] ++
          source_fields(a_to_b) ++ source_fields(b_to_a) ++ rate_fields(rate) ++
          [Integer.to_string(quote_cleared), Integer.to_string(base_cleared)]

      {:ok,
       %{
         schema: @schema,
         intent_id: intent_id,
         observed_at: now,
         a_to_b: a_to_b,
         b_to_a: b_to_a,
         rate: rate,
         source_reductions: [reduction_a, reduction_b],
         totals_by_currency: totals,
         totals_scope: :per_currency_no_scalar_aggregation,
         rounding: :exact_minor_units_only,
         status: :unadmitted_preview_only,
         authority: :host_assertions_unverified,
         consent: :not_verified,
         legal_classification: :undetermined,
         discharge: :not_executed,
         accounting_posting: :requires_independent_valuation_and_authorization,
         financial_settlement: :none,
         currency_exchange: :none,
         terms_hash: B.digest(fields)
       }}
    end
  end

  def propose(_, _, _, _, _), do: {:error, :invalid_request}

  @doc "Recompute every preview field, refusing altered sources, rates or outputs."
  def verify_plan(%{a_to_b: a, b_to_a: b, rate: rate, intent_id: id} = candidate, now) do
    case propose(a, b, rate, id, now) do
      {:ok, ^candidate} -> {:ok, candidate}
      _ -> {:error, :invalid_cross_currency_plan}
    end
  end

  def verify_plan(_, _), do: {:error, :invalid_cross_currency_plan}

  defp validate_sources(a, b, intent_id, now) do
    cond do
      not (valid_source?(a, now) and valid_source?(b, now)) ->
        {:error, :invalid_source}

      not B.valid_public_id?(intent_id) or intent_id in [a.id, b.id] ->
        {:error, :invalid_intent_id}

      a.id == b.id ->
        {:error, :duplicate_source}

      a.debtor != b.creditor or a.creditor != b.debtor ->
        {:error, :not_reciprocal_principals}

      a.currency == b.currency ->
        {:error, :same_currency_use_ledger_first}

      true ->
        :ok
    end
  end

  defp valid_source?(%{} = source, now) do
    Enum.sort(Map.keys(source)) == Enum.sort(@source_keys) and
      B.valid_public_id?(source.id) and
      B.valid_public_id?(source.debtor) and
      B.valid_public_id?(source.creditor) and
      source.debtor != source.creditor and
      currency?(source.currency) and
      bounded_positive?(source.amount_minor) and
      bounded_positive?(source.revision) and
      reference?(source.evidence_ref) and
      is_integer(source.valid_until) and source.valid_until > now and
      source.status == :host_declared_eligible
  end

  defp valid_source?(_, _), do: false

  defp validate_rate(rate, quote, base, now) do
    cond do
      Enum.sort(Map.keys(rate)) != Enum.sort(@rate_keys) ->
        {:error, :invalid_rate_shape}

      rate.quote_currency != quote or rate.base_currency != base ->
        {:error, :currency_pair_mismatch}

      not (currency?(base) and currency?(quote) and base != quote) ->
        {:error, :invalid_currency_pair}

      not (bounded_positive?(rate.numerator) and bounded_positive?(rate.denominator)) ->
        {:error, :invalid_rate}

      Integer.gcd(rate.numerator, rate.denominator) != 1 ->
        {:error, :noncanonical_rate}

      not (is_integer(rate.agreed_at) and rate.agreed_at >= 0 and rate.agreed_at <= now and
             is_integer(rate.valid_until) and rate.valid_until > now) ->
        {:error, :expired_or_future_rate}

      not (reference?(rate.evidence_ref) and reference?(rate.agreement_ref)) ->
        {:error, :missing_agreement_reference}

      true ->
        :ok
    end
  end

  defp exact_reduction(quote_available, base_available, %{numerator: n, denominator: d}) do
    # Each unit of d base minor units is valued at n quote minor units.
    # Dividing available amounts first avoids unnecessary large products.
    multiples = min(div(base_available, d), div(quote_available, n))

    if multiples == 0 do
      {:error, :no_exact_minor_unit_offset}
    else
      {:ok, multiples * n, multiples * d}
    end
  end

  defp source_reduction(source, reduction) do
    %{
      source_id: source.id,
      source_revision: source.revision,
      currency: source.currency,
      original_minor: source.amount_minor,
      proposed_reduction_minor: reduction,
      residual_minor: source.amount_minor - reduction,
      status: :unadmitted_preview
    }
  end

  defp source_fields(source) do
    [
      source.id,
      source.debtor,
      source.creditor,
      source.currency,
      Integer.to_string(source.amount_minor),
      Integer.to_string(source.revision),
      source.evidence_ref,
      Integer.to_string(source.valid_until),
      Atom.to_string(source.status)
    ]
  end

  defp rate_fields(rate) do
    [
      rate.base_currency,
      rate.quote_currency,
      Integer.to_string(rate.numerator),
      Integer.to_string(rate.denominator),
      Integer.to_string(rate.agreed_at),
      Integer.to_string(rate.valid_until),
      rate.evidence_ref,
      rate.agreement_ref
    ]
  end

  defp currency?(value) when is_binary(value),
    do: String.match?(value, ~r/\A[A-Z]{3}\z/)

  defp currency?(_), do: false

  defp reference?(value) when is_binary(value), do: byte_size(value) in 1..256
  defp reference?(_), do: false

  defp bounded_positive?(value),
    do: is_integer(value) and value > 0 and value <= @max_minor
end
