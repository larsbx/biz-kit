defmodule CommerceCore.MerchantPilot.SourcingBounty do
  @moduledoc false

  @max_minor 9_007_199_254_740_991

  def post(row, now, terms) do
    cond do
      Map.has_key?(row, :bounty) or map_size(row.quotes) > 0 ->
        {:error, :bounty_terms_already_fixed}

      now >= row.request.needed_by_ms ->
        {:error, :bounty_deadline_passed}

      not valid_amounts?(terms) ->
        {:error, :invalid_bounty_terms}

      true ->
        {:ok, Map.put(row, :bounty, Map.put(terms, :award, nil))}
    end
  end

  defp valid_amounts?(%{reward_minor: reward, maximum_total_minor: maximum}) do
    is_integer(reward) and is_integer(maximum) and reward > 0 and
      reward <= maximum and maximum <= @max_minor
  end

  def validate_quote(%{bounty: terms, request: request}, now, previous, quote) do
    sourcing_business = quote[:sourcing_business_id]

    cond do
      now >= request.needed_by_ms ->
        {:error, :bounty_deadline_passed}

      previous != nil and previous[:sourcing_business_id] != sourcing_business ->
        {:error, :sourcing_business_mismatch}

      sourcing_business in [request.buyer_business_id, quote.merchant_business_id] ->
        {:error, :independent_sourcing_business_required}

      all_in_total(terms, quote) > terms.maximum_total_minor ->
        {:error, :bounty_budget_exceeded}

      true ->
        :ok
    end
  end

  def validate_quote(_, _, _, %{sourcing_business_id: _}), do: {:error, :bounty_missing}
  def validate_quote(_, _, _, _), do: :ok

  def all_in_total(terms, quote) do
    quote.total_minor +
      if(Map.has_key?(quote, :sourcing_business_id), do: terms.reward_minor, else: 0)
  end

  def award(%{bounty: _, request: %{needed_by_ms: deadline}}, now) when now >= deadline,
    do: {:error, :bounty_deadline_passed}

  def award(%{bounty: terms, accepted_quote: %{sourcing_business_id: business} = quote} = row, _) do
    award = %{
      sourcing_business_id: business,
      quote_id: quote.quote_id,
      quote_revision: quote.revision,
      delivery_ref: nil,
      delivered_on_time: false,
      closeout_ref: nil,
      payment_ref: nil
    }

    {:ok, %{row | bounty: %{terms | award: award}}}
  end

  def award(row, _), do: {:ok, row}

  def record_delivery(%{bounty: %{award: %{} = award}} = row, event_at_ms) do
    delivery = %{
      award
      | delivery_ref: row.outcome_ref,
        delivered_on_time: event_at_ms < row.request.needed_by_ms
    }

    put_in(row.bounty.award, delivery)
  end

  def record_delivery(row, _), do: row

  def record_result(
        %{bounty: %{award: %{delivered_on_time: true, closeout_ref: nil}}} = row,
        :confirm_bounty,
        evidence_ref
      ),
      do: {:ok, put_in(row.bounty.award.closeout_ref, evidence_ref)}

  def record_result(
        %{bounty: %{award: %{closeout_ref: closeout, payment_ref: nil}}} = row,
        :bounty_payment_evidence,
        evidence_ref
      )
      when is_binary(closeout),
      do: {:ok, put_in(row.bounty.award.payment_ref, evidence_ref)}

  def record_result(_, _, _), do: {:error, :bounty_result_not_admissible}
end
