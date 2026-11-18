defmodule CommerceCore.MerchantPilot.Intake do
  @moduledoc "Pure projection of source-owned online extracts to scorecard v1 and private provenance."
  import CommerceCore.MerchantPilot.Validation
  alias CommerceCore.MerchantPilot.{JSON, Scorecard}
  @collections ~w(merchants requests invitations quotes fee_arrangements orders costs)
  @cost_kinds ~w(acquisition processing inspection storage handling shipping fraud returns support operations insurance other)
  def collections, do: @collections

  def assemble!(control, prepared) do
    fields!(control, "intake_version dataset pilot cohort_started_at as_of coverage")
    bundle = Map.merge(control, Map.new(@collections, &{&1, []}))

    Enum.reduce(rows!(prepared), bundle, fn row, acc ->
      fields!(row, "collection record")
      check!(row["collection"] in @collections, :collection)
      Map.update!(acc, row["collection"], &(&1 ++ [row["record"]]))
    end)
  end

  def quote_key(pilot, row) do
    JSON.digest([pilot, row["source_id"], row["owner_id"], row["record_id"], row["revision"]])
    |> binary_part(0, 32)
  end

  defp quote_ref!(ref) do
    fields!(ref, "source_id record_id revision")
    token!(ref["source_id"])
    token!(ref["record_id"])
    positive!(ref["revision"])
    {ref["source_id"], ref["record_id"], ref["revision"]}
  end

  def export!(bundle) do
    fields!(
      bundle,
      "intake_version dataset pilot cohort_started_at as_of coverage " <>
        Enum.join(@collections, " ")
    )

    check!(bundle["intake_version"] === 1, :intake_version)
    check!(bundle["dataset"] in ~w(synthetic observed), :dataset)
    start = time!(bundle["cohort_started_at"])
    cutoff = time!(bundle["as_of"])
    check!(start <= cutoff, :observation_interval)
    pilot = fields!(bundle["pilot"], "id geography category approval_ref")
    Enum.each(~w(id geography category), &token!(pilot[&1]))
    unless is_nil(pilot["approval_ref"]), do: token!(pilot["approval_ref"])
    check!(bundle["dataset"] == "synthetic" or not is_nil(pilot["approval_ref"]), :approval)
    coverage = read_coverage!(bundle, start, cutoff)
    {records, crosswalk} = read_records!(bundle, coverage, start, cutoff)
    merchants = read_merchants!(records["merchants"], start, cutoff)
    {requests, admitted, excluded} = read_requests!(records["requests"], pilot, start, cutoff)
    invitations = read_invitations!(records["invitations"], merchants, admitted)
    {quote_rows, quotes} = read_quotes!(records["quotes"], pilot, merchants, admitted)
    arrangements = read_arrangements!(records["fee_arrangements"], merchants)
    costs = read_costs!(records["costs"], start, cutoff)
    orders = read_orders!(records["orders"], merchants, quotes, arrangements, costs, cutoff)
    order_currencies = Map.new(orders, &{&1["id"], &1["currency"]})

    Enum.each(costs, fn {{id, _, currency}, _} ->
      check!(is_nil(id) or Map.has_key?(order_currencies, id), :cost_order)
      check!(is_nil(id) or currency == order_currencies[id], :cost_currency)
    end)

    codes =
      (Enum.map(Map.values(admitted), & &1["currency"]) ++
         Enum.map(quote_rows, & &1["currency"]) ++ Enum.map(Map.keys(costs), &elem(&1, 2)))
      |> Enum.uniq()
      |> Enum.sort()

    unallocated =
      for currency <- codes,
          role <- roles(),
          do: %{
            "currency" => currency,
            "role" => role,
            "minor" => Map.get(costs, {nil, role, currency})
          }

    snapshot = %{
      "schema_version" => 1,
      "dataset" => bundle["dataset"],
      "cohort_started_at" => bundle["cohort_started_at"],
      "as_of" => bundle["as_of"],
      "requests" => Enum.sort_by(requests, & &1["id"]),
      "invitations" => Enum.sort_by(invitations, &{&1["request_id"], &1["merchant_id"]}),
      "quotes" => Enum.sort_by(quote_rows, & &1["id"]),
      "orders" => Enum.sort_by(orders, & &1["id"]),
      "unallocated_costs" => unallocated
    }

    Scorecard.score!(snapshot)

    manifest = %{
      "intake_version" => 1,
      "dataset" => bundle["dataset"],
      "pilot" => pilot,
      "as_of" => bundle["as_of"],
      "coverage" => Enum.sort_by(bundle["coverage"], &{&1["collection"], &1["source_id"]}),
      "excluded_requests" => excluded,
      "records" =>
        Enum.sort_by(
          crosswalk,
          &{&1["collection"], &1["source_id"], &1["record_id"], &1["revision"]}
        ),
      "quote_ids" =>
        for(
          {{source, record, revision}, {quote, _}} <- Enum.sort(quotes),
          do: %{
            "source_id" => source,
            "record_id" => record,
            "revision" => revision,
            "scorecard_id" => quote["id"]
          }
        ),
      "snapshot_sha256" => JSON.digest(snapshot)
    }

    {snapshot, manifest}
  end

  defp read_coverage!(bundle, start, cutoff) do
    coverage =
      Enum.reduce(rows!(bundle["coverage"]), %{}, fn row, acc ->
        fields!(row, "source_id owner_id collection from through evidence_ref")
        Enum.each(~w(source_id owner_id evidence_ref), &token!(row[&1]))
        check!(row["collection"] in @collections, :collection)
        check!(time!(row["from"]) <= start and time!(row["through"]) >= cutoff, :coverage)
        unique!(acc, {row["source_id"], row["collection"]}, row["owner_id"])
      end)

    check!(
      coverage
      |> Map.keys()
      |> Enum.map(&elem(&1, 1))
      |> MapSet.new()
      |> MapSet.equal?(MapSet.new(@collections)),
      :coverage
    )

    coverage
  end

  defp read_records!(bundle, coverage, start, cutoff) do
    Enum.reduce(@collections, {%{}, []}, fn collection, {records, crosswalk} ->
      {seen, latest, crosswalk} =
        Enum.reduce(rows!(bundle[collection]), {%{}, MapSet.new(), crosswalk}, fn row,
                                                                                  {seen, latest,
                                                                                   crosswalk} ->
          fields!(row, "source_id owner_id record_id revision captured_at evidence_refs data")
          Enum.each(~w(source_id owner_id record_id), &token!(row[&1]))
          positive!(row["revision"])
          occurred!(row["captured_at"], start, cutoff)
          evidence!(row["evidence_refs"])

          check!(
            Map.get(coverage, {row["source_id"], collection}) == row["owner_id"],
            :source_owner
          )

          seen = unique!(seen, {row["source_id"], row["record_id"], row["revision"]}, true)
          key = {row["source_id"], row["record_id"]}
          check!(collection == "quotes" or not MapSet.member?(latest, key), :ambiguous_revisions)
          check!(is_map(row["data"]), :record_data)
          {seen, MapSet.put(latest, key), [Map.put(row, "collection", collection) | crosswalk]}
        end)

      _ = {seen, latest}
      {Map.put(records, collection, bundle[collection]), crosswalk}
    end)
  end

  defp read_merchants!(rows, start, cutoff) do
    {merchants, _} =
      Enum.reduce(rows, {%{}, MapSet.new()}, fn row, {acc, businesses} ->
        d = fields!(row["data"], "id business_id opted_in_at withdrawn_at participation_ref")
        Enum.each(~w(id business_id participation_ref), &token!(d[&1]))
        check!(row["owner_id"] == d["id"], :merchant_owner)
        check!(not MapSet.member?(businesses, d["business_id"]), :business_identity)
        opted = occurred!(d["opted_in_at"], start, cutoff)
        occurred!(d["withdrawn_at"], opted, cutoff, true)
        {unique!(acc, d["id"], d), MapSet.put(businesses, d["business_id"])}
      end)

    merchants
  end

  defp active!(merchants, id, at) do
    m = ref!(merchants, id)
    instant = time!(at)

    check!(
      time!(m["opted_in_at"]) <= instant and
        (is_nil(m["withdrawn_at"]) or instant < time!(m["withdrawn_at"])),
      :merchant_inactive
    )
  end

  defp read_requests!(rows, pilot, start, cutoff) do
    {all, admitted, excluded, requests} =
      Enum.reduce(rows, {%{}, %{}, %{}, []}, fn row, {all, admitted, excluded, requests} ->
        d =
          fields!(
            row["data"],
            "id buyer_key geography category specification_ref condition_ref quantity needed_by budget_minor currency submitted_at qualified_at status duplicate_of withdrawn_at consent observed_through"
          )

        Enum.each(
          ~w(id buyer_key geography category specification_ref condition_ref),
          &token!(d[&1])
        )

        positive!(d["quantity"])
        amount!(d["budget_minor"], true)
        currency!(d["currency"])
        submitted = occurred!(d["submitted_at"], start, cutoff)
        check!(time!(d["needed_by"]) >= submitted, :needed_by)
        check!(d["status"] in ~w(qualified rejected duplicate unreviewed), :qualification_status)
        unless is_nil(d["duplicate_of"]), do: token!(d["duplicate_of"])
        check!(d["status"] == "duplicate" == not is_nil(d["duplicate_of"]), :duplicate_link)

        consent =
          fields!(
            d["consent"],
            "revision_ref granted_at sharing_revoked_at measurement_authorized"
          )

        token!(consent["revision_ref"])
        grant = occurred!(consent["granted_at"], submitted, cutoff, true)
        revoked = occurred!(consent["sharing_revoked_at"], grant || submitted, cutoff, true)
        flag!(consent["measurement_authorized"])
        qualified = occurred!(d["qualified_at"], submitted, cutoff, true)
        withdrawal = occurred!(d["withdrawn_at"], qualified || submitted, cutoff, true)
        all = unique!(all, d["id"], d)

        if d["status"] != "qualified" do
          check!(is_nil(qualified), :excluded_qualification)
          {all, admitted, Map.put(excluded, d["id"], d["status"]), requests}
        else
          check!(
            d["geography"] == pilot["geography"] and d["category"] == pilot["category"],
            :scope
          )

          check!(
            not is_nil(qualified) and not is_nil(grant) and grant <= qualified and
              (is_nil(revoked) or qualified < revoked),
            :consent
          )

          check!(consent["measurement_authorized"], :retention)
          check!(time!(d["observed_through"]) >= cutoff, :request_followup)
          ends = Enum.reject([withdrawal, revoked], &is_nil/1)
          effective = if ends == [], do: nil, else: utc(Enum.min(ends))

          result = %{
            "id" => d["id"],
            "qualified_at" => d["qualified_at"],
            "withdrawn_at" => effective
          }

          {all, Map.put(admitted, d["id"], d), excluded, [result | requests]}
        end
      end)

    Enum.each(Map.values(all), fn d ->
      unless is_nil(d["duplicate_of"]) do
        original = ref!(admitted, d["duplicate_of"])
        check!(original["buyer_key"] == d["buyer_key"], :duplicate_buyer)
      end
    end)

    {requests, admitted, excluded}
  end

  defp read_invitations!(rows, merchants, admitted) do
    {_, invitations} =
      Enum.reduce(rows, {%{}, []}, fn row, {seen, acc} ->
        d = fields!(row["data"], "request_id merchant_id invited_at responded_at")
        check!(Map.has_key?(admitted, d["request_id"]), :excluded_invitation)
        active!(merchants, d["merchant_id"], d["invited_at"])
        {unique!(seen, {d["request_id"], d["merchant_id"]}, true), [d | acc]}
      end)

    invitations
  end

  defp read_quotes!(rows, pilot, merchants, admitted) do
    quotes =
      Enum.reduce(rows, %{}, fn row, acc ->
        d =
          fields!(
            row["data"],
            "request_id merchant_id issued_at expires_at withdrawn_at qualified currency price_minor tax_minor shipping_minor buyer_fee_minor supersedes_revision item_evidence_ref stock_evidence_ref"
          )

        unless is_nil(d["supersedes_revision"]), do: positive!(d["supersedes_revision"])
        check!(row["owner_id"] == d["merchant_id"], :quote_owner)
        check!(Map.has_key?(admitted, d["request_id"]), :excluded_quote)
        Enum.each(~w(item_evidence_ref stock_evidence_ref), &token!(d[&1]))
        active!(merchants, d["merchant_id"], d["issued_at"])
        Enum.each(~w(price_minor tax_minor shipping_minor buyer_fee_minor), &amount!(d[&1]))
        check!(d["buyer_fee_minor"] == 0, :buyer_fee)
        check!(d["currency"] == admitted[d["request_id"]]["currency"], :quote_currency)

        q =
          Map.take(
            d,
            ~w(request_id merchant_id issued_at expires_at withdrawn_at qualified currency)
          )
          |> Map.put("id", quote_key(pilot["id"], row))
          |> Map.put(
            "all_in_minor",
            Enum.sum(Enum.map(~w(price_minor tax_minor shipping_minor buyer_fee_minor), &d[&1]))
          )

        unique!(acc, {row["source_id"], row["record_id"], row["revision"]}, {q, row})
      end)

    chains = Enum.group_by(quotes, fn {{source, record, _}, _} -> {source, record} end)

    quotes =
      Enum.reduce(Map.values(chains), quotes, fn chain, acc ->
        sorted = Enum.sort_by(chain, fn {{_, _, revision}, _} -> revision end)
        {_, {_, first}} = hd(sorted)

        check!(
          first["revision"] == 1 and is_nil(first["data"]["supersedes_revision"]),
          :quote_original
        )

        sorted
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.reduce(acc, fn [{key, {old, prev}}, {_, {new, row}}], acc ->
          check!(
            row["revision"] == prev["revision"] + 1 and
              row["data"]["supersedes_revision"] == prev["revision"],
            :revision_gap
          )

          check!(
            {row["owner_id"], new["merchant_id"], new["request_id"]} ==
              {prev["owner_id"], old["merchant_id"], old["request_id"]},
            :revision_identity
          )

          check!(time!(old["issued_at"]) < time!(new["issued_at"]), :revision_order)
          ending = [old["withdrawn_at"], new["issued_at"]] |> Enum.reject(&is_nil/1) |> Enum.min()
          Map.put(acc, key, {Map.put(old, "withdrawn_at", ending), prev})
        end)
      end)

    {Enum.map(Map.values(quotes), &elem(&1, 0)), quotes}
  end

  defp read_arrangements!(rows, merchants) do
    Enum.reduce(rows, %{}, fn row, acc ->
      d =
        fields!(
          row["data"],
          "id merchant_id servicing_store_id currency payer valid_from valid_until terms_ref"
        )

      Enum.each(~w(id terms_ref), &token!(d[&1]))
      active!(merchants, d["merchant_id"], d["valid_from"])

      unless is_nil(d["servicing_store_id"]),
        do: active!(merchants, d["servicing_store_id"], d["valid_from"])

      currency!(d["currency"])
      check!(d["payer"] == "merchant", :fee_payer)
      check!(time!(d["valid_from"]) < time!(d["valid_until"]), :fee_interval)
      unique!(acc, d["id"], d)
    end)
  end

  defp read_costs!(rows, start, cutoff) do
    {costs, _} =
      Enum.reduce(rows, {%{}, MapSet.new()}, fn row, {acc, ids} ->
        d = fields!(row["data"], "order_id role currency complete items")
        unless is_nil(d["order_id"]), do: token!(d["order_id"])
        check!(d["role"] in roles(), :cost_role)
        currency!(d["currency"])
        flag!(d["complete"])

        {sum, known, ids} =
          Enum.reduce(rows!(d["items"]), {0, d["complete"], ids}, fn item, {sum, known, ids} ->
            fields!(item, "id kind minor incurred_at evidence_ref")
            token!(item["id"])
            token!(item["evidence_ref"])
            check!(not MapSet.member?(ids, item["id"]), :duplicate_expense)
            check!(item["kind"] in @cost_kinds, :cost_kind)
            amount!(item["minor"], true)
            occurred!(item["incurred_at"], start, cutoff)

            {sum + (item["minor"] || 0), known and not is_nil(item["minor"]),
             MapSet.put(ids, item["id"])}
          end)

        {unique!(acc, {d["order_id"], d["role"], d["currency"]}, if(known, do: sum, else: nil)),
         ids}
      end)

    costs
  end

  defp read_orders!(rows, merchants, quotes, arrangements, costs, cutoff) do
    {_, orders} =
      Enum.reduce(rows, {%{}, []}, fn row, {seen, acc} ->
        d =
          fields!(
            row["data"],
            "id quote_ref servicing_store_id currency accepted_at promised_by outcome outcome_at paid_at returned_at disputed_at reconciled_at gross_minor refunds fees fee_arrangement_id stock_terms_revalidated provider_verified observed_through"
          )

        token!(d["id"])
        seen = unique!(seen, d["id"], true)
        key = quote_ref!(d["quote_ref"])
        check!(Map.has_key?(quotes, key), :accepted_quote)
        {q, _} = quotes[key]
        active!(merchants, q["merchant_id"], d["accepted_at"])
        flag!(d["stock_terms_revalidated"])
        flag!(d["provider_verified"])
        check!(d["stock_terms_revalidated"], :stock_revalidation)
        check!(is_nil(d["paid_at"]) or d["provider_verified"], :provider_payment)
        check!(time!(d["observed_through"]) >= cutoff, :order_followup)
        a = ref!(arrangements, d["fee_arrangement_id"])

        check!(
          {a["merchant_id"], a["servicing_store_id"], a["currency"]} ==
            {q["merchant_id"], d["servicing_store_id"], d["currency"]},
          :fee_identity
        )

        check!(
          time!(a["valid_from"]) <= time!(d["accepted_at"]) and
            time!(d["accepted_at"]) < time!(a["valid_until"]),
          :inactive_fee
        )

        unless is_nil(d["servicing_store_id"]),
          do: active!(merchants, d["servicing_store_id"], d["accepted_at"])

        refunds =
          for refund <- rows!(d["refunds"]) do
            fields!(refund, "id at minor evidence_ref provider_verified")
            token!(refund["evidence_ref"])
            flag!(refund["provider_verified"])
            check!(refund["provider_verified"], :provider_refund)
            Map.take(refund, ~w(id at minor))
          end

        expenses = Map.new(roles(), &{&1, Map.get(costs, {d["id"], &1, d["currency"]})})

        expenses =
          if is_nil(d["servicing_store_id"]) do
            pool = {d["id"], "servicing_store", d["currency"]}
            check!(not Map.has_key?(costs, pool) or costs[pool] == 0, :absent_store)
            Map.put(expenses, "servicing_store", 0)
          else
            expenses
          end

        out =
          Map.take(
            d,
            ~w(id servicing_store_id currency accepted_at promised_by outcome outcome_at paid_at returned_at disputed_at reconciled_at gross_minor fees)
          )
          |> Map.merge(%{"quote_id" => q["id"], "refunds" => refunds, "costs_minor" => expenses})

        {seen, [out | acc]}
      end)

    orders
  end
end
