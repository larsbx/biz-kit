defmodule CommerceCore.MerchantPilot.Scorecard do
  @moduledoc "Pure v1 pilot scorecard. Reads maps and returns measurements, without executing commerce."
  import CommerceCore.MerchantPilot.Validation
  @week 604_800
  @month 2_592_000
  @quarter 7_776_000
  def score!(snapshot, opts \\ []) do
    fields!(
      snapshot,
      "schema_version dataset cohort_started_at as_of requests invitations quotes orders unallocated_costs"
    )

    check!(snapshot["schema_version"] === 1, :schema_version)
    check!(snapshot["dataset"] in ~w(synthetic observed), :dataset)
    start = time!(snapshot["cohort_started_at"])
    cutoff = time!(snapshot["as_of"])
    check!(start <= cutoff, :observation_interval)
    {requests, invitations, quotes} = read_demand!(snapshot, start, cutoff)
    orders = read_orders!(snapshot, requests, quotes, start, cutoff)

    overhead =
      Enum.reduce(rows!(snapshot["unallocated_costs"]), %{}, fn row, acc ->
        fields!(row, "currency role minor")
        currency!(row["currency"])
        check!(row["role"] in roles(), :cost_role)
        amount!(row["minor"], true)
        unique!(acc, {row["currency"], row["role"]}, row["minor"])
      end)

    demand = demand_metrics(requests, invitations, quotes, cutoff)

    accepted_requests =
      orders
      |> Map.values()
      |> Enum.map(&quotes[&1["quote_id"]]["request_id"])
      |> Enum.uniq()
      |> length()

    %{
      "schema_version" => 1,
      "dataset" => snapshot["dataset"],
      "cohort_started_at" => snapshot["cohort_started_at"],
      "as_of" => snapshot["as_of"],
      "demand" => Map.put(demand, "requests_with_accepted_order", accepted_requests),
      "orders" => outcome_metrics(Map.values(orders), cutoff),
      "economics" =>
        summarize_margins(orders, overhead, Keyword.get(opts, :include_orders, false))
    }
  end

  defp read_demand!(snapshot, start, cutoff) do
    requests =
      Enum.reduce(rows!(snapshot["requests"]), %{}, fn row, acc ->
        fields!(row, "id qualified_at withdrawn_at")
        token!(row["id"])
        qualified = occurred!(row["qualified_at"], start, cutoff)
        withdrawn = occurred!(row["withdrawn_at"], qualified, cutoff, true)
        unique!(acc, row["id"], {qualified, withdrawn})
      end)

    invitations =
      Enum.reduce(rows!(snapshot["invitations"]), %{}, fn row, acc ->
        fields!(row, "request_id merchant_id invited_at responded_at")
        {qualified, withdrawn} = ref!(requests, row["request_id"])
        token!(row["merchant_id"])
        invited = occurred!(row["invited_at"], qualified, cutoff)
        check!(is_nil(withdrawn) or invited < withdrawn, :invitation_after_withdrawal)
        responded = occurred!(row["responded_at"], invited, cutoff, true)
        unique!(acc, {row["request_id"], row["merchant_id"]}, {invited, responded})
      end)

    quotes =
      Enum.reduce(rows!(snapshot["quotes"]), %{}, fn row, acc ->
        fields!(
          row,
          "id request_id merchant_id issued_at expires_at withdrawn_at qualified currency all_in_minor"
        )

        token!(row["id"])
        ref!(requests, row["request_id"])
        token!(row["merchant_id"])
        key = {row["request_id"], row["merchant_id"]}
        check!(Map.has_key?(invitations, key), :quote_invitation)
        {_, responded} = invitations[key]
        check!(not is_nil(responded), :quote_response)
        issued = occurred!(row["issued_at"], responded, cutoff)
        expires = time!(row["expires_at"])
        check!(issued < expires, :quote_expiry)
        withdrawn = occurred!(row["withdrawn_at"], issued, cutoff, true)
        flag!(row["qualified"])
        currency!(row["currency"])
        amount!(row["all_in_minor"])

        unique!(
          acc,
          row["id"],
          Map.merge(row, %{
            "issued_at" => issued,
            "expires_at" => expires,
            "withdrawn_at" => withdrawn
          })
        )
      end)

    {requests, invitations, quotes}
  end

  defp actionable?(q, withdrawn, instant) do
    q["qualified"] and q["issued_at"] <= instant and instant < q["expires_at"] and
      (is_nil(q["withdrawn_at"]) or instant < q["withdrawn_at"]) and
      (is_nil(withdrawn) or instant < withdrawn)
  end

  defp ratio(n, d), do: %{"numerator" => n, "denominator" => d}

  defp followup(rows, predicate, total),
    do:
      Map.put(
        ratio(Enum.count(rows, predicate), length(rows)),
        "incomplete",
        total - length(rows)
      )

  defp demand_metrics(requests, invitations, quotes, cutoff) do
    first =
      Enum.reduce(Map.values(quotes), %{}, fn q, acc ->
        {qualified, withdrawn} = requests[q["request_id"]]
        issued = q["issued_at"]

        if actionable?(q, withdrawn, issued) and issued - qualified <= @week,
          do: Map.update(acc, q["request_id"], issued, &min(&1, issued)),
          else: acc
      end)

    {mature, early} =
      Enum.reduce(requests, {%{}, 0}, fn {id, {qualified, withdrawn}}, {acc, n} ->
        cond do
          not is_nil(withdrawn) and withdrawn - qualified < @week -> {acc, n + 1}
          cutoff - qualified >= @week -> {Map.put(acc, id, qualified + @week), n}
          true -> {acc, n}
        end
      end)

    latencies =
      for {id, _} <- mature, Map.has_key?(first, id), do: first[id] - elem(requests[id], 0)

    responses =
      for {{request, _}, {invited, responded}} <- invitations,
          Map.has_key?(mature, request) and invited <= mature[request],
          do: not is_nil(responded) and responded <= mature[request]

    %{
      "qualified_requests" => map_size(requests),
      "seven_day_match" =>
        Map.merge(ratio(length(latencies), map_size(mature)), %{
          "incomplete" => map_size(requests) - map_size(mature) - early,
          "withdrawn_early" => early
        }),
      "first_quote_within_seven_days" => %{
        "median_seconds" => median(latencies),
        "observed" => length(latencies),
        "unmatched_mature" => map_size(mature) - length(latencies)
      },
      "seven_day_invitation_response" => ratio(Enum.count(responses, & &1), length(responses))
    }
  end

  defp median([]), do: nil

  defp median(values) do
    sorted = Enum.sort(values)
    n = length(sorted)

    if rem(n, 2) == 1,
      do: Enum.at(sorted, div(n, 2)) / 1,
      else: (Enum.at(sorted, div(n, 2) - 1) + Enum.at(sorted, div(n, 2))) / 2
  end

  defp order_economics!(row, accepted, paid, cutoff, refund_ids) do
    gross = amount!(row["gross_minor"], true)
    check!(not is_nil(paid) or gross in [nil, 0], :payment_required)
    reconciled = occurred!(row["reconciled_at"], accepted, cutoff, true)

    {refunded, refund_ids} =
      Enum.reduce(rows!(row["refunds"]), {0, refund_ids}, fn refund, {sum, ids} ->
        fields!(refund, "id at minor")
        token!(refund["id"])
        ids = unique!(ids, refund["id"], true)
        check!(not is_nil(paid), :refund_payment)
        occurred!(refund["at"], paid, reconciled || cutoff)
        positive!(refund["minor"])
        {sum + refund["minor"], ids}
      end)

    check!(refunded == 0 or (not is_nil(gross) and refunded <= gross), :refund_exceeds_gross)
    fees = fields!(row["fees"], "servicing_store platform")
    costs = fields!(row["costs_minor"], "merchant servicing_store platform")

    net =
      Map.new(fees, fn {role, fee} ->
        value = if is_nil(fee), do: nil, else: net_fee!(fee)
        {role, value}
      end)

    Enum.each(Map.values(costs), &amount!(&1, true))

    if is_nil(row["servicing_store_id"]) do
      check!(
        fees["servicing_store"] == %{"gross_minor" => 0, "reversed_minor" => 0} and
          costs["servicing_store"] == 0,
        :absent_store
      )
    end

    merchant =
      if Enum.any?([gross | Map.values(net)], &is_nil/1),
        do: nil,
        else: gross - refunded - Enum.sum(Map.values(net))

    {reconciled, Map.put(net, "merchant", merchant), refund_ids}
  end

  defp net_fee!(fee) do
    fields!(fee, "gross_minor reversed_minor")
    amount!(fee["gross_minor"])
    amount!(fee["reversed_minor"])
    check!(fee["reversed_minor"] <= fee["gross_minor"], :fee_reversal)
    fee["gross_minor"] - fee["reversed_minor"]
  end

  defp read_orders!(snapshot, requests, quotes, start, cutoff) do
    {orders, _, _, attempts} =
      Enum.reduce(rows!(snapshot["orders"]), {%{}, %{}, %{}, %{}}, fn row,
                                                                      {orders, bound, ids,
                                                                       attempts} ->
        fields!(
          row,
          "id quote_id servicing_store_id currency accepted_at promised_by outcome outcome_at paid_at returned_at disputed_at reconciled_at gross_minor refunds fees costs_minor"
        )

        token!(row["id"])
        quote = ref!(quotes, row["quote_id"])
        {_, withdrawn} = requests[quote["request_id"]]
        accepted = occurred!(row["accepted_at"], start, cutoff)
        check!(actionable?(quote, withdrawn, accepted), :inactive_quote)
        bound = unique!(bound, row["quote_id"], true)

        unless is_nil(row["servicing_store_id"]) do
          token!(row["servicing_store_id"])
          check!(row["servicing_store_id"] != quote["merchant_id"], :supplier_is_store)
        end

        check!(row["currency"] == quote["currency"], :order_currency)
        promise = time!(row["promised_by"])
        check!(accepted <= promise, :promise)
        outcome = row["outcome"]
        check!(outcome in ~w(pending fulfilled failed cancelled), :outcome)
        completed = occurred!(row["outcome_at"], accepted, cutoff, outcome == "pending")
        check!(outcome == "pending" == is_nil(completed), :outcome_timestamp)
        paid = occurred!(row["paid_at"], accepted, cutoff, true)
        returned = occurred!(row["returned_at"], completed || accepted, cutoff, true)
        check!(is_nil(returned) or outcome == "fulfilled", :return_without_fulfillment)
        disputed = occurred!(row["disputed_at"], accepted, cutoff, true)
        {reconciled, revenue, ids} = order_economics!(row, accepted, paid, cutoff, ids)

        unless is_nil(reconciled),
          do:
            check!(
              not is_nil(completed) and
                Enum.all?(
                  [completed, paid, returned, disputed],
                  &(is_nil(&1) or &1 <= reconciled)
                ),
              :reconciliation
            )

        realized =
          if not is_nil(paid) and outcome == "fulfilled", do: max(paid, completed), else: nil

        order =
          Map.merge(row, %{
            "merchant_id" => quote["merchant_id"],
            "accepted_at" => accepted,
            "realized_at" => realized,
            "on_time" => outcome == "fulfilled" and completed <= promise,
            "returned_at" => returned,
            "disputed_at" => disputed,
            "reconciled_at" => reconciled,
            "revenue" => revenue,
            "promised_by" => promise
          })

        {unique!(orders, row["id"], order), bound, ids,
         Map.update(
           attempts,
           quote["request_id"],
           [{accepted, completed, outcome}],
           &[{accepted, completed, outcome} | &1]
         )}
      end)

    Enum.each(Map.values(attempts), fn entries ->
      entries
      |> Enum.sort()
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [{_, finished, state}, {next, _, _}] ->
        check!(state in ~w(failed cancelled) and finished < next, :overlapping_acceptance)
      end)
    end)

    orders
  end

  defp outcome_metrics(orders, cutoff) do
    final = Enum.filter(orders, &(&1["outcome"] != "pending"))
    disputes = Enum.filter(orders, &(cutoff - &1["accepted_at"] >= @month))

    cohorts =
      orders
      |> Enum.reject(&is_nil(&1["realized_at"]))
      |> Enum.group_by(& &1["merchant_id"], & &1["realized_at"])
      |> Map.values()
      |> Enum.map(&Enum.sort/1)

    repeat = Enum.filter(cohorts, &(cutoff - hd(&1) >= @quarter))

    %{
      "accepted_orders" => length(orders),
      "realized_orders" => Enum.sum(Enum.map(cohorts, &length/1)),
      "on_time_fulfillment" =>
        Map.put(
          followup(final, & &1["on_time"], length(orders)),
          "pending_past_promise",
          Enum.count(orders, &(&1["outcome"] == "pending" and &1["promised_by"] <= cutoff))
        ),
      "cancelled" => ratio(Enum.count(final, &(&1["outcome"] == "cancelled")), length(final)),
      "returns_to_date" =>
        ratio(
          Enum.count(final, &(not is_nil(&1["returned_at"]))),
          Enum.count(final, &(&1["outcome"] == "fulfilled"))
        ),
      "refunded_orders_to_date" =>
        ratio(Enum.count(orders, &(&1["refunds"] != [])), length(orders)),
      "intervention_disputes_30_day" =>
        followup(
          disputes,
          &(not is_nil(&1["disputed_at"]) and &1["disputed_at"] - &1["accepted_at"] <= @month),
          length(orders)
        ),
      "merchant_repeat_90_day" =>
        followup(
          repeat,
          &(length(&1) >= 2 and Enum.at(&1, 1) - hd(&1) <= @quarter),
          length(cohorts)
        )
    }
  end

  defp margin(revenue, cost, shock), do: revenue - cost - div(cost * shock + 9999, 10000)

  defp summarize_margins(orders, overhead, include_orders) do
    grouped =
      Enum.reduce(Map.values(orders), %{}, fn order, acc ->
        Enum.reduce(roles(), acc, fn role, acc ->
          if role != "servicing_store" or not is_nil(order["servicing_store_id"]),
            do:
              Map.update(
                acc,
                {order["currency"], role},
                [{order, order["revenue"][role], order["costs_minor"][role]}],
                &[{order, order["revenue"][role], order["costs_minor"][role]} | &1]
              ),
            else: acc
        end)
      end)

    keys = Enum.sort(Enum.uniq(Map.keys(grouped) ++ Map.keys(overhead)))

    {aggregates, details} =
      Enum.reduce(keys, {%{}, %{}}, fn {code, role} = key, {agg, details} ->
        entries = Map.get(grouped, key, [])

        {known, missing, open, details} =
          Enum.reduce(entries, {[], 0, 0, details}, fn {order, revenue, cost},
                                                       {known, missing, open, details} ->
            status =
              cond do
                is_nil(order["reconciled_at"]) -> "unreconciled"
                is_nil(revenue) or is_nil(cost) -> "missing_inputs"
                true -> "complete"
              end

            detail =
              if status == "complete",
                do: %{
                  "status" => status,
                  "revenue_minor" => revenue,
                  "incremental_cost_minor" => cost,
                  "margin_minor" => revenue - cost,
                  "cost_headroom_minor" => revenue - cost
                },
                else: %{"status" => status}

            details =
              if include_orders,
                do:
                  Map.update(details, order["id"], %{role => detail}, &Map.put(&1, role, detail)),
                else: details

            {if(status == "complete", do: [{revenue, cost} | known], else: known),
             missing + if(status == "missing_inputs", do: 1, else: 0),
             open + if(status == "unreconciled", do: 1, else: 0), details}
          end)

        unallocated = Map.get(overhead, key, 0)
        complete = length(known) == length(entries) and not is_nil(unallocated)

        scenarios =
          for shock <- [0, 1000, 2500] do
            margins = Enum.map(known, fn {r, c} -> margin(r, c, shock) end)

            %{
              "added_cost_basis_points" => shock,
              "known_orders_margin_minor" => if(known == [], do: nil, else: Enum.sum(margins)),
              "nonpositive_known_orders" => Enum.count(margins, &(&1 <= 0)),
              "negative_known_orders" => Enum.count(margins, &(&1 < 0)),
              "cohort_margin_minor" =>
                if(complete, do: Enum.sum(margins) + margin(0, unallocated, shock), else: nil)
            }
          end

        value = %{
          "accepted" => length(entries),
          "complete" => length(known),
          "unreconciled" => open,
          "missing_inputs" => missing,
          "known_orders_revenue_minor" =>
            if(known == [], do: nil, else: Enum.sum(Enum.map(known, &elem(&1, 0)))),
          "known_orders_cost_minor" =>
            if(known == [], do: nil, else: Enum.sum(Enum.map(known, &elem(&1, 1)))),
          "unallocated_cost_minor" => unallocated,
          "scenarios" => scenarios
        }

        {Map.update(agg, code, %{role => value}, &Map.put(&1, role, value)), details}
      end)

    result = %{"by_currency" => aggregates}

    if include_orders,
      do:
        Map.put(
          result,
          "orders",
          for(
            id <- Enum.sort(Map.keys(details)),
            do: %{"id" => id, "currency" => orders[id]["currency"], "roles" => details[id]}
          )
        ),
      else: result
  end
end
