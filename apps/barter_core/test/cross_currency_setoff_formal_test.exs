defmodule BarterCore.CrossCurrencySetoffFormalTest do
  use ExUnit.Case, async: true

  alias BarterCore.CrossCurrencySetoff, as: Setoff

  @now 1_800_000_000
  @intent "https://alpha.example/clearing/formal-boundary"
  @max 9_007_199_254_740_991

  defp claims do
    quote = %{
      id: "https://alpha.example/obligations/quote",
      debtor: "https://alpha.example/actors/business",
      creditor: "https://beta.example/actors/business",
      currency: "USD",
      amount_minor: 10,
      revision: 1,
      evidence_ref: "quote-assertion",
      valid_until: @now + 100,
      status: :host_declared_eligible
    }

    base = %{
      quote
      | id: "https://beta.example/obligations/base",
        debtor: quote.creditor,
        creditor: quote.debtor,
        currency: "EUR",
        amount_minor: 5,
        evidence_ref: "base-assertion"
    }

    rate = %{
      base_currency: "EUR",
      quote_currency: "USD",
      numerator: 3,
      denominator: 2,
      agreed_at: @now - 1,
      valid_until: @now + 50,
      evidence_ref: "rate-assertion",
      agreement_ref: "agreement-assertion"
    }

    {quote, base, rate}
  end

  defp preview(quote, base, rate, now \\ @now),
    do: Setoff.propose(quote, base, rate, @intent, now)

  test "self-consistency verification does not authenticate a latest source revision" do
    {quote, base, rate} = claims()
    assert {:ok, original} = preview(quote, base, rate)

    for {field, source, row_index} <- [{:a_to_b, quote, 0}, {:b_to_a, base, 1}],
        changed <- [
          %{source | revision: 2},
          %{source | id: source.id <> "/substituted"},
          %{source | evidence_ref: "fabricated-but-well-shaped-assertion"}
        ] do
      assert {:error, :invalid_cross_currency_plan} =
               Setoff.verify_plan(Map.put(original, field, changed), @now)

      inputs = Map.put(%{a_to_b: quote, b_to_a: base}, field, changed)
      assert {:ok, rebuilt} = preview(inputs.a_to_b, inputs.b_to_a, rate)
      assert {:ok, ^rebuilt} = Setoff.verify_plan(rebuilt, @now)
      assert Map.fetch!(rebuilt, field) == changed
      row = Enum.at(rebuilt.source_reductions, row_index)
      assert row.source_id == changed.id
      assert row.source_revision == changed.revision
      assert row.currency == changed.currency
      refute rebuilt.terms_hash == original.terms_hash
      assert rebuilt.authority == :host_assertions_unverified
      assert rebuilt.consent == :not_verified
      assert rebuilt.legal_classification == :undetermined

      # There is no independently supplied latest source to consult.
      assert {:ok, ^original} = Setoff.verify_plan(original, @now)
    end
  end

  test "verification binds the observation time even before source or rate expiry" do
    {quote, base, rate} = claims()
    assert {:ok, original} = preview(quote, base, rate)
    assert {:error, :invalid_cross_currency_plan} = Setoff.verify_plan(original, @now + 1)
    assert {:ok, refreshed} = preview(quote, base, rate, @now + 1)
    assert {:ok, ^refreshed} = Setoff.verify_plan(refreshed, @now + 1)
    refute refreshed.terms_hash == original.terms_hash
    assert refreshed.totals_by_currency == original.totals_by_currency
  end

  test "agreement and source time boundaries are explicit host assertions" do
    {quote, base, rate} = claims()
    assert {:ok, _} = preview(quote, base, %{rate | agreed_at: @now, valid_until: @now + 1})

    for changed <- [
          %{rate | agreed_at: @now + 1},
          %{rate | agreed_at: -1},
          %{rate | valid_until: @now},
          %{rate | valid_until: @now - 1}
        ] do
      assert {:error, :expired_or_future_rate} = preview(quote, base, changed)
    end

    assert {:ok, _} = preview(%{quote | valid_until: @now + 1}, base, rate)
    assert {:error, :invalid_source} = preview(%{quote | valid_until: @now}, base, rate)
    assert {:error, :invalid_source} = preview(quote, %{base | valid_until: @now}, rate)
  end

  test "length-prefixed UTF-8 agreement fields distinguish ambiguous concatenations" do
    {quote, base, rate} = claims()
    left = %{rate | evidence_ref: "é:12", agreement_ref: "合同"}
    right = %{rate | evidence_ref: "é:", agreement_ref: "12合同"}
    assert left.evidence_ref <> left.agreement_ref == right.evidence_ref <> right.agreement_ref
    assert {:ok, first} = preview(quote, base, left)
    assert {:ok, second} = preview(quote, base, right)
    assert first.totals_by_currency == second.totals_by_currency
    refute first.terms_hash == second.terms_hash
    assert {:ok, ^first} = Setoff.verify_plan(first, @now)
    assert {:ok, ^second} = Setoff.verify_plan(second, @now)

    assert BarterCore.digest(["é:12", "合同"]) != BarterCore.digest(["é:", "12合同"])
    assert BarterCore.digest(["1", "23"]) != BarterCore.digest(["12", "3"])
  end

  test "rounding edits can conserve totals while violating the declared rational" do
    {quote, base, rate} = claims()
    assert {:ok, plan} = preview(quote, base, rate)
    [q, b] = plan.source_reductions
    rounded_q = %{q | proposed_reduction_minor: 7, residual_minor: 3}
    rounded_b = %{b | proposed_reduction_minor: 5, residual_minor: 0}

    assert rounded_q.original_minor ==
             rounded_q.proposed_reduction_minor + rounded_q.residual_minor

    assert rounded_b.original_minor ==
             rounded_b.proposed_reduction_minor + rounded_b.residual_minor

    refute rounded_q.proposed_reduction_minor * rate.denominator ==
             rounded_b.proposed_reduction_minor * rate.numerator

    totals =
      [rounded_q, rounded_b]
      |> Enum.map(
        &Map.take(&1, [:currency, :original_minor, :proposed_reduction_minor, :residual_minor])
      )
      |> Enum.sort_by(& &1.currency)

    assert {:error, :invalid_cross_currency_plan} =
             Setoff.verify_plan(
               %{plan | source_reductions: [rounded_q, rounded_b], totals_by_currency: totals},
               @now
             )
  end

  test "same scalar sum does not justify combining or swapping currencies" do
    {quote, base, rate} = claims()
    assert {:ok, plan} = preview(quote, base, rate)
    [eur, usd] = plan.totals_by_currency

    aggregate = %{
      currency: "USD",
      original_minor: eur.original_minor + usd.original_minor,
      proposed_reduction_minor: eur.proposed_reduction_minor + usd.proposed_reduction_minor,
      residual_minor: eur.residual_minor + usd.residual_minor
    }

    assert aggregate.original_minor ==
             aggregate.proposed_reduction_minor + aggregate.residual_minor

    for changed <- [
          %{plan | totals_by_currency: [aggregate]},
          %{plan | totals_by_currency: [%{eur | currency: "USD"}, %{usd | currency: "EUR"}]},
          %{plan | source_reductions: Enum.reverse(plan.source_reductions)},
          Map.put(plan, :total_minor, aggregate.original_minor)
        ] do
      assert {:error, :invalid_cross_currency_plan} = Setoff.verify_plan(changed, @now)
    end
  end

  test "canonical rates and large boundary amounts never use binary floats" do
    {quote, base, rate} = claims()

    for {amount, expected} <- [
          {0, :invalid_source},
          {-1, :invalid_source},
          {@max + 1, :invalid_source}
        ] do
      assert {:error, ^expected} = preview(%{quote | amount_minor: amount}, base, rate)
    end

    for invalid <- [0, -1, 1.0, @max + 1] do
      assert {:error, :invalid_rate} = preview(quote, base, %{rate | numerator: invalid})
      assert {:error, :invalid_rate} = preview(quote, base, %{rate | denominator: invalid})
    end

    assert {:error, :noncanonical_rate} =
             preview(quote, base, %{rate | numerator: 6, denominator: 4})

    assert {:ok, large} =
             preview(%{quote | amount_minor: @max}, %{base | amount_minor: @max}, %{
               rate
               | numerator: @max,
                 denominator: @max - 1
             })

    assert Enum.map(large.source_reductions, & &1.proposed_reduction_minor) == [@max, @max - 1]
    assert Enum.map(large.source_reductions, & &1.residual_minor) == [0, 1]
    assert {:ok, ^large} = Setoff.verify_plan(large, @now)
  end
end
