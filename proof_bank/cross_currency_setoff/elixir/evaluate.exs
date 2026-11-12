# Execute the real preview over a deterministic TSV arithmetic corpus. The
# optional source argument is used only by deliberate negative-control runs.
root = Path.expand("../../..", __DIR__)
Code.require_file(Path.join(root, "apps/barter_core/lib/barter_core.ex"))

source =
  case System.argv() do
    [] -> Path.join(root, "apps/barter_core/lib/barter_core/cross_currency_setoff.ex")
    [path] -> path
  end

Code.require_file(source)

defmodule CrossCurrencySetoffComparison do
  alias BarterCore.CrossCurrencySetoff

  def source(id, debtor, creditor, amount, currency) do
    %{
      id: "https://proof.example/obligations/" <> id,
      debtor: "https://" <> debtor <> ".example/business",
      creditor: "https://" <> creditor <> ".example/business",
      amount_minor: amount,
      currency: currency,
      revision: 1,
      evidence_ref: "unsigned-host-assertion:" <> id,
      valid_until: 200,
      status: :host_declared_eligible
    }
  end

  def evaluate([quote, base, numerator, denominator]) do
    a = source("quote", "alpha", "beta", quote, "USD")
    b = source("base", "beta", "alpha", base, "EUR")

    rate = %{
      base_currency: "EUR",
      quote_currency: "USD",
      numerator: numerator,
      denominator: denominator,
      agreed_at: 99,
      valid_until: 150,
      evidence_ref: "unsigned-valuation",
      agreement_ref: "unsigned-agreement"
    }

    case CrossCurrencySetoff.propose(a, b, rate, "https://proof.example/intents/one", 100) do
      {:ok, plan} ->
        # These are observable implementation checks, not source authentication.
        {:ok, ^plan} = CrossCurrencySetoff.verify_plan(plan, 100)
        ^a = plan.a_to_b
        ^b = plan.b_to_a
        [q, r] = plan.source_reductions
        true = q.source_id == a.id and r.source_id == b.id
        true = q.source_revision == a.revision and r.source_revision == b.revision
        true = q.currency == "USD" and r.currency == "EUR"
        true = q.original_minor == quote and r.original_minor == base
        true = plan.totals_scope == :per_currency_no_scalar_aggregation
        true = plan.status == :unadmitted_preview_only
        true = plan.legal_classification == :undetermined
        true = plan.discharge == :not_executed
        true = plan.financial_settlement == :none and plan.currency_exchange == :none
        true = length(plan.totals_by_currency) == 2

        [
          2,
          q.proposed_reduction_minor,
          r.proposed_reduction_minor,
          q.residual_minor,
          r.residual_minor
        ]

      {:error, :no_exact_minor_unit_offset} ->
        [1, 0, 0, quote, base]

      {:error, _reason} ->
        [0, 0, 0, quote, base]
    end
  end
end

IO.stream(:stdio, :line)
|> Enum.each(fn line ->
  values = line |> String.trim() |> String.split("\t") |> Enum.map(&String.to_integer/1)
  [_, _, _, _] = values
  result = CrossCurrencySetoffComparison.evaluate(values)
  IO.puts(Enum.join(result, "\t"))
end)
