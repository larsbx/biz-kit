defmodule BarterCore.CrossCurrencySetoffTest do
  use ExUnit.Case, async: true

  alias BarterCore.CrossCurrencySetoff, as: Setoff

  @now 1_800_000_000
  @intent "https://alpha.example/clearing/intent-1"

  defp actor(id), do: "https://#{id}.example/actors/merchant"

  defp source(id, debtor, creditor, amount, currency) do
    %{
      id: "https://alpha.example/obligations/#{id}",
      debtor: actor(debtor),
      creditor: actor(creditor),
      amount_minor: amount,
      currency: currency,
      revision: 1,
      evidence_ref: "local-host-asserted-#{id}",
      valid_until: @now + 1000,
      status: :host_declared_eligible
    }
  end

  defp quote, do: source("usd", "alpha", "beta", 1_000_000, "USD")
  defp base, do: source("eur", "beta", "alpha", 800_000, "EUR")

  # Units: USD cents per EUR cent, NOT USD major units per EUR major unit.
  defp rate do
    %{
      base_currency: "EUR",
      quote_currency: "USD",
      numerator: 11,
      denominator: 10,
      agreed_at: @now - 10,
      valid_until: @now + 500,
      evidence_ref: "host-asserted-negotiated-valuation",
      agreement_ref: "unsigned-negotiation-reference"
    }
  end

  defp propose(q \\ quote(), b \\ base(), r \\ rate()) do
    Setoff.propose(q, b, r, @intent, @now)
  end

  test "cross-currency mutual offset produces two exact conserved currency ledgers" do
    assert {:ok, plan} = propose()

    assert plan.source_reductions == [
             %{
               source_id: quote().id,
               source_revision: 1,
               currency: "USD",
               original_minor: 1_000_000,
               proposed_reduction_minor: 880_000,
               residual_minor: 120_000,
               status: :unadmitted_preview
             },
             %{
               source_id: base().id,
               source_revision: 1,
               currency: "EUR",
               original_minor: 800_000,
               proposed_reduction_minor: 800_000,
               residual_minor: 0,
               status: :unadmitted_preview
             }
           ]

    assert plan.totals_by_currency == [
             %{
               currency: "EUR",
               original_minor: 800_000,
               proposed_reduction_minor: 800_000,
               residual_minor: 0
             },
             %{
               currency: "USD",
               original_minor: 1_000_000,
               proposed_reduction_minor: 880_000,
               residual_minor: 120_000
             }
           ]

    assert Enum.all?(plan.totals_by_currency, fn total ->
             total.original_minor ==
               total.proposed_reduction_minor + total.residual_minor
           end)

    assert plan.totals_scope == :per_currency_no_scalar_aggregation
    assert plan.rounding == :exact_minor_units_only
    assert plan.status == :unadmitted_preview_only
    assert plan.authority == :host_assertions_unverified
    assert plan.consent == :not_verified
    assert plan.legal_classification == :undetermined
    assert plan.discharge == :not_executed
    assert plan.currency_exchange == :none
    assert plan.financial_settlement == :none
    assert plan.accounting_posting == :requires_independent_valuation_and_authorization
    assert {:ok, ^plan} = Setoff.verify_plan(plan, @now)
  end

  test "partial exact setoff never invents a fractional cent or adds currencies" do
    assert {:ok, plan} =
             propose(source("usd", "alpha", "beta", 10, "USD"),
               source("eur", "beta", "alpha", 5, "EUR"),
               %{rate() | numerator: 3, denominator: 2}
             )

    assert Enum.map(plan.source_reductions, fn p ->
             {p.currency, p.proposed_reduction_minor, p.residual_minor}
           end) == [{"USD", 6, 4}, {"EUR", 4, 1}]

    assert {:ok, ^plan} = Setoff.verify_plan(plan, @now)
  end

  test "refuses a wholly fractional offset rather than rounding or fabricating value" do
    assert {:error, :no_exact_minor_unit_offset} =
             propose(source("usd", "alpha", "beta", 10, "USD"),
               source("eur", "beta", "alpha", 1, "EUR"),
               %{rate() | numerator: 3, denominator: 2}
             )
  end

  test "source revision, amount, rate, evidence, and output edits invalidate verification" do
    assert {:ok, original} = propose()

    changes = [
      %{original | a_to_b: %{original.a_to_b | revision: 2}},
      %{original | b_to_a: %{original.b_to_a | amount_minor: 700_000}},
      %{original | rate: %{original.rate | numerator: 12}},
      %{original | rate: %{original.rate | agreement_ref: "different-contract"}},
      %{original | totals_by_currency: []},
      %{original | source_reductions: []},
      %{original | terms_hash: "corrupted"},
      %{original | discharge: :executed}
    ]

    for altered <- changes do
      assert {:error, :invalid_cross_currency_plan} = Setoff.verify_plan(altered, @now)
    end

    assert {:ok, another} = propose(%{quote() | revision: 2})
    refute original.terms_hash == another.terms_hash
    assert {:ok, another} = propose(quote(), base(), %{rate() | numerator: 12})
    refute original.terms_hash == another.terms_hash
  end

  test "rejects missing source provenance, unrecognized shapes, float and stale inputs" do
    for altered <- [
          %{quote() | amount_minor: 0},
          %{quote() | amount_minor: 1.5},
          %{quote() | valid_until: @now},
          %{quote() | evidence_ref: ""},
          %{quote() | status: :approved},
          Map.put(quote(), :bank_instruction, "transfer"),
          Map.delete(quote(), :revision)
        ] do
      assert {:error, :invalid_source} = propose(altered)
    end
  end

  test "rejects self-dealing, nonreciprocal principals, duplicate sources and same currency" do
    assert {:error, :invalid_source} =
             propose(%{quote() | creditor: quote().debtor})

    assert {:error, :not_reciprocal_principals} =
             propose(quote(), %{base() | debtor: actor("gamma")})

    assert {:error, :duplicate_source} =
             propose(quote(), %{base() | id: quote().id})

    assert {:error, :same_currency_use_ledger_first} =
             propose(quote(), %{base() | currency: "USD"})
  end

  test "rate must be explicitly dated, canonical, bounded and source-currency matched" do
    for {altered, expected} <- [
          {%{rate() | numerator: 0}, :invalid_rate},
          {%{rate() | numerator: 1.1}, :invalid_rate},
          {%{rate() | denominator: 0}, :invalid_rate},
          {%{rate() | numerator: 22, denominator: 20}, :noncanonical_rate},
          {%{rate() | valid_until: @now}, :expired_or_future_rate},
          {%{rate() | agreed_at: @now + 1}, :expired_or_future_rate},
          {%{rate() | agreement_ref: ""}, :missing_agreement_reference},
          {%{rate() | evidence_ref: ""}, :missing_agreement_reference},
          {%{rate() | base_currency: "GBP"}, :currency_pair_mismatch},
          {Map.put(rate(), :permission_to_fx, true), :invalid_rate_shape}
        ] do
      assert {:error, ^expected} = propose(quote(), base(), altered)
    end
  end

  test "no authority is created by otherwise valid exact cross-currency arithmetic" do
    assert {:ok, plan} = propose()

    refute Map.has_key?(plan, :signed_event)
    refute Map.has_key?(plan, :journal)
    refute Map.has_key?(plan, :payment_instruction)
    refute Map.has_key?(plan, :fx_execution)
    refute Map.has_key?(plan, :gross_minor)

    assert {:error, :invalid_cross_currency_plan} =
             Setoff.verify_plan(%{plan | status: :admitted}, @now)
  end

  test "invalid requests and reusing source ID as intent ID fail closed" do
    assert {:error, :invalid_intent_id} =
             Setoff.propose(quote(), base(), rate(), quote().id, @now)

    assert {:error, :invalid_request} =
             Setoff.propose(quote(), base(), rate(), @intent, "now")

    assert {:error, :invalid_cross_currency_plan} = Setoff.verify_plan(%{}, @now)
  end

  test "maximum minor-unit amounts remain exact without float arithmetic" do
    max = 9_007_199_254_740_991

    assert {:ok, plan} =
             propose(source("usd", "alpha", "beta", max, "USD"),
               source("eur", "beta", "alpha", max, "EUR"),
               %{rate() | numerator: 1, denominator: 1}
             )

    assert Enum.all?(plan.totals_by_currency, fn x ->
             x.original_minor == max and x.proposed_reduction_minor == max and
               x.residual_minor == 0
           end)
  end
end
